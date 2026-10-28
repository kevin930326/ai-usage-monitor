"""跨裝置的 AI 狀態（ADR-0019 第 2 節）。不連網：假的中繼照 relay/src/agents.ts 的規則運作，
密鑰以 mock 取代 Keychain／認證管理員。

golden：
- `fixtures/agent/golden.json` 的 summary（Swift、C# 產生的 agent-state.json）必須原樣通過 `read_state`；
- `fixtures/agent/sync-cases.json` → `sync-golden.json`（收集器才有的規則：驗證 agent-state.json、
  把中繼回應轉成 agent-remote.json）。
  規則有意改變時 `AUM_UPDATE_GOLDEN=1 python3 -m unittest tests.test_agent_sync` 重新產生，檢查 `git diff` 後提交。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import agent_sync, credentials, history
from usage_collector.http import HTTPStatusError
from usage_collector.models import ProviderError

AGENT = Path(__file__).resolve().parents[2] / "fixtures" / "agent"
NOW = 1_792_000_000
URL = "https://relay.example.dev"
OWN = "11111111-1111-4111-8111-111111111111"
STATE = json.dumps({"v": 1, "ais": [{"ai": "claude", "state": "needsYou", "sessions": 1, "since": 5}]})


class GoldenTests(unittest.TestCase):
    def test_summary_lines_from_swift_and_csharp_pass_unchanged(self):
        golden = json.loads((AGENT / "golden.json").read_text(encoding="utf-8"))
        lines = [line.split(" summary ", 1)[1] for case in golden["sessions"] for line in case["result"] if " summary " in line]
        self.assertGreater(len(lines), 5)
        for line in lines:
            body = agent_sync.read_state(line.encode())
            self.assertIsNotNone(body, line)
            self.assertEqual(line, agent_sync.encode(body))

    def test_sync_golden(self):
        cases = json.loads((AGENT / "sync-cases.json").read_text(encoding="utf-8"))
        output = {
            "state_files": [{"name": c["name"], "result": self._state(c["raw"])} for c in cases["state_files"]],
            "relay": [{"name": c["name"], "result": self._relay(c)} for c in cases["relay"]],
        }
        path = AGENT / "sync-golden.json"
        if os.environ.get("AUM_UPDATE_GOLDEN") == "1":
            path.write_text(json.dumps(output, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), output)

    @staticmethod
    def _state(raw: str) -> str:
        body = agent_sync.read_state(raw.encode())
        return "nil" if body is None else agent_sync.encode(body)

    @staticmethod
    def _relay(case: dict) -> str:
        try:
            response = json.loads(case["raw"])
        except ValueError:
            return "nil"
        remote = agent_sync.remote_file(response, set(case["own"]), case["fetched_at"])
        return "nil" if remote is None else agent_sync.encode(remote)

    def test_relay_output_has_no_device_ids(self):
        golden = json.loads((AGENT / "sync-golden.json").read_text(encoding="utf-8"))
        for case in golden["relay"]:
            self.assertNotIn("device_id", case["result"])
            self.assertNotIn("1111", case["result"])


class FakeRelay:
    """照 relay/src/agents.ts：裝置密鑰 → device_id、整台覆蓋；讀取密鑰下載全部。"""

    def __init__(self):
        self.calls: list[tuple[str, str, dict | None]] = []
        self.fail: list[Exception] = []
        self.devices: list[dict] = []
        self.accepted: list[dict] = []

    def __call__(self, url, headers, body=None, timeout=15):
        self.calls.append((url, headers["Authorization"], body))
        if self.fail:
            raise self.fail.pop(0)
        if body is not None:
            self.accepted.append(body)
            return {"ok": True}
        return {"now": NOW * 1000, "devices": self.devices}

    def uploads(self):
        """中繼收下的上傳（失敗的不算）"""
        return self.accepted


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.db = self.dir / "history.sqlite3"
        self.config = self.dir / "config.json"
        self.config.write_text(json.dumps({"agent_sync": True, "relay_url": URL}), encoding="utf-8")
        self.state = self.dir / "agent-state.json"
        self.remote = self.dir / "agent-remote.json"
        self.relay = FakeRelay()
        self.keys = {credentials.DEVICE_KEY: "aumd_" + "x" * 43, credentials.READ_KEY: "read-secret-0123456789"}
        self.sleeps: list[float] = []
        for target, value in [("usage_collector.agent_sync.request_json", self.relay),
                              ("usage_collector.agent_sync.STATE_PATH", self.state),
                              ("usage_collector.agent_sync.REMOTE_PATH", self.remote),
                              ("usage_collector.agent_sync.credentials.read", lambda name: self.keys.get(name)),
                              ("usage_collector.agent_sync.time.sleep", self.sleeps.append)]:
            patcher = mock.patch(target, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        conn = history.connect(self.db)
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('relay_device_id', ?)", (OWN,))
        conn.close()

    def write_state(self, text: str = STATE, age: float = 0) -> None:
        self.state.write_text(text, encoding="utf-8")
        os.utime(self.state, (NOW - age, NOW - age))

    def run_sync(self, now: int = NOW, running: bool = True) -> None:
        agent_sync.run(self.db, now=now, config_path=self.config, running=lambda: running)

    def test_off_or_without_tier2_does_nothing(self):
        self.write_state()
        self.config.write_text(json.dumps({"agent_sync": False, "relay_url": URL}), encoding="utf-8")
        self.run_sync()
        self.config.write_text(json.dumps({"agent_sync": True, "relay_url": "http://plain.example"}), encoding="utf-8")
        self.run_sync()
        self.assertEqual([], self.relay.calls)
        self.config.write_text(json.dumps({"agent_sync": True, "relay_url": URL}), encoding="utf-8")
        conn = history.connect(self.db)
        conn.execute("DELETE FROM meta WHERE key = 'relay_device_id'")
        conn.close()
        self.run_sync()
        self.assertEqual([], self.relay.calls)

    def test_uploads_state_and_skips_same_content_until_heartbeat(self):
        self.write_state()
        self.run_sync()
        self.assertEqual([{"ais": json.loads(STATE)["ais"]}], self.relay.uploads())
        self.assertEqual(f"{URL}/agents/state", self.relay.calls[0][0])
        self.assertEqual("Bearer " + self.keys[credentials.DEVICE_KEY], self.relay.calls[0][1])
        self.write_state(age=0)
        self.run_sync(NOW + 120)
        self.assertEqual(1, len(self.relay.uploads()))
        self.run_sync(NOW + agent_sync.HEARTBEAT)
        self.assertEqual(2, len(self.relay.uploads()))

    def test_change_within_a_minute_waits_and_sends_the_latest(self):
        self.write_state()
        self.run_sync()
        self.write_state(STATE.replace("needsYou", "working"))
        self.run_sync(NOW + 20)
        self.assertEqual([40], self.sleeps)
        self.assertEqual("working", self.relay.uploads()[-1]["ais"][0]["state"])

    def test_change_during_the_wait_is_what_gets_sent(self):
        self.write_state()
        self.run_sync()
        self.write_state(STATE.replace("needsYou", "working"))
        # 等候的 40 秒內 App 又寫了一次：送出的是等完後讀到的
        with mock.patch("usage_collector.agent_sync.time.sleep",
                        lambda _: self.write_state(STATE.replace("needsYou", "done"))):
            self.run_sync(NOW + 20)
        self.assertEqual(2, len(self.relay.uploads()))
        self.assertEqual("done", self.relay.uploads()[-1]["ais"][0]["state"])

    def test_app_not_running_or_stale_file_uploads_idle_once(self):
        self.write_state()
        self.run_sync()
        self.run_sync(NOW + 100, running=False)
        self.assertEqual({"ais": []}, self.relay.uploads()[-1])
        self.run_sync(NOW + 5000, running=False)
        self.assertEqual(2, len(self.relay.uploads()))
        self.write_state(age=agent_sync.STALE + 1)
        self.run_sync(NOW + 6000)
        self.assertEqual(2, len(self.relay.uploads()))

    def test_404_waits_an_hour_and_logs_once(self):
        self.write_state()
        self.relay.fail = [HTTPStatusError("HTTP 404", 404)]
        with mock.patch("usage_collector.agent_sync.log") as log:
            self.run_sync()
            self.run_sync(NOW + 600)
            self.assertEqual(1, len([c for c in log.call_args_list if "還不支援" in c.args[0]]))
        uploads = [c for c in self.relay.calls if c[2] is not None]
        self.assertEqual(1, len(uploads))
        self.run_sync(NOW + agent_sync.NOT_SUPPORTED_RETRY)
        self.assertEqual(1, len(self.relay.uploads()))

    def test_network_error_retries_in_five_minutes(self):
        self.write_state()
        self.relay.fail = [ProviderError("網路錯誤")]
        self.run_sync()
        self.run_sync(NOW + 100)
        self.assertEqual([], self.relay.uploads())
        self.run_sync(NOW + agent_sync.RETRY)
        self.assertEqual(1, len(self.relay.uploads()))

    def test_download_writes_others_without_ids(self):
        self.write_state()
        self.relay.devices = [
            {"device_id": OWN, "name": "這台", "ais": [], "updated_at": NOW * 1000},
            {"device_id": "33333333-3333-4333-8333-333333333333", "name": "桌機",
             "ais": [{"ai": "codex", "state": "needsYou", "sessions": 1, "since": 1}], "updated_at": NOW * 1000 - 5000},
        ]
        self.run_sync()
        remote = json.loads(self.remote.read_text(encoding="utf-8"))
        self.assertEqual({"v": 1, "fetched_at": NOW * 1000, "now": NOW * 1000, "devices": [
            {"name": "桌機", "ais": [{"ai": "codex", "state": "needsYou", "sessions": 1, "since": 1}],
             "updated_at": NOW * 1000 - 5000}]},
            remote)
        self.assertNotIn("3333", self.remote.read_text(encoding="utf-8"))
        # 沒有讀取密鑰：只上傳
        del self.keys[credentials.READ_KEY]
        self.remote.unlink()
        self.run_sync(NOW + 120)
        self.assertFalse(self.remote.exists())

    def test_another_sync_in_progress_is_waited_for(self):
        # 另一個同步拿著鎖：等它結束才讀進度與狀態，送出的是等完後的最新狀態（Codex C-01）
        lock = self.dir / agent_sync.LOCK_FILE
        lock.touch()
        self.write_state()

        def other_finishes(_):
            self.write_state(STATE.replace("needsYou", "done"))
            lock.unlink(missing_ok=True)

        with mock.patch("usage_collector.agent_sync.time.sleep", other_finishes):
            self.run_sync()
        self.assertEqual("done", self.relay.uploads()[-1]["ais"][0]["state"])
        self.assertFalse(lock.exists())

    def test_lock_held_too_long_skips_and_stale_lock_is_taken(self):
        lock = self.dir / agent_sync.LOCK_FILE
        lock.touch()
        self.write_state()
        self.run_sync()
        self.assertEqual([], self.relay.calls)
        self.assertEqual(agent_sync.LOCK_WAIT, len(self.sleeps))
        self.assertTrue(lock.exists())  # 別人的鎖不刪
        old = time.time() - agent_sync.STALE_LOCK - 1
        os.utime(lock, (old, old))
        self.run_sync()
        self.assertEqual(1, len(self.relay.uploads()))
        self.assertFalse(lock.exists())

    def test_never_raises(self):
        with mock.patch("usage_collector.agent_sync.run", side_effect=RuntimeError("boom /Users/me")), \
                mock.patch("usage_collector.agent_sync.log") as log:
            agent_sync.run_safely()
        self.assertEqual("略過 AI 狀態同步：RuntimeError", log.call_args.args[0])


class AppRunningTests(unittest.TestCase):
    def test_missing_socket_means_not_running(self):
        with mock.patch("usage_collector.agent_sync.APP_SUPPORT_DIR", Path(tempfile.mkdtemp())):
            if os.name != "nt":
                self.assertFalse(agent_sync.app_running())


if __name__ == "__main__":
    unittest.main()


class SetTier2Tests(unittest.TestCase):
    """set-tier2.sh --agent-sync／--no-agent-sync：只改 config.json 的 agent_sync，不提示密鑰；第二層沒開時停止"""

    def run_script(self, home: Path, flag: str) -> subprocess.CompletedProcess:
        script = Path(__file__).resolve().parents[1] / "scripts" / "set-tier2.sh"
        env = {"PATH": f"{Path(sys.executable).parent}:/usr/bin:/bin", "HOME": str(home), "AI_USAGE_MONITOR_HOME": str(home),
               "LANG": "en_US.UTF-8"}
        return subprocess.run([str(script), flag], env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def test_flags_toggle_agent_sync_only(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            config = home / "config.json"
            config.write_text(json.dumps({"relay_url": URL}), encoding="utf-8")
            result = self.run_script(home, "--agent-sync")
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("agent_sync", json.loads(config.read_text(encoding="utf-8")))
            config.write_text(json.dumps({"relay_url": URL, "token_sync": True}), encoding="utf-8")
            result = self.run_script(home, "--agent-sync")
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIs(True, json.loads(config.read_text(encoding="utf-8"))["agent_sync"])
            (home / "agent-remote.json").write_text("{}", encoding="utf-8")
            result = self.run_script(home, "--no-agent-sync")
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIs(False, json.loads(config.read_text(encoding="utf-8"))["agent_sync"])
            self.assertFalse((home / "agent-remote.json").exists())

