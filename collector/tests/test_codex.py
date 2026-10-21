import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector.models import ProviderError
from usage_collector.providers import codex

FIXTURES = Path(__file__).parent / "fixtures" / "codex"
RATE_LIMITS = json.loads((FIXTURES / "rate-limits-team.json").read_text())

# 假的 codex：Python 腳本，照真的 app-server 一行一個 JSON-RPC 訊息回應。
# MODE 控制行為；每次啟動都把 pid、工作目錄與收到的訊息記錄下來，讓測試檢查有沒有留下程序、送了什麼
FAKE = r'''
import json, os, signal, subprocess, sys, time
MODE, RESULT, LOG = {mode!r}, {result!r}, {log!r}
FIXTURES = {fixtures!r}
if sys.argv[1:] != ["app-server", "--listen", "stdio://"]:
    sys.exit(98)
log = open(LOG, "a")
def record(**kw):
    log.write(json.dumps(kw) + "\n"); log.flush()
record(pid=os.getpid(), cwd=os.getcwd(), stdin_is_pipe=not os.isatty(0), path=os.environ.get("PATH", ""))
print("person@example.com token=secret", file=sys.stderr, flush=True)
if MODE in ("ignore-eof", "ignore-term"):
    child = subprocess.Popen(["sleep", "60"])
    record(child=child.pid)
if MODE == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
def reply(msg):
    sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    msg = json.loads(line)
    record(received=msg)
    method = msg.get("method")
    if method == "initialize":
        reply(json.load(open(os.path.join(FIXTURES, "notification.json"))))
        reply({{"id": msg["id"], "result": json.load(open(os.path.join(FIXTURES, "initialize.json")))}})
    elif method == "account/rateLimits/read":
        if MODE == "hang":
            continue
        if MODE == "exit":
            sys.exit(3)
        if MODE == "garbage":
            sys.stdout.write("not json person@example.com\n"); sys.stdout.flush(); continue
        if MODE == "flood":
            while True:
                sys.stdout.write("x" * 65536); sys.stdout.flush()
        if MODE == "server-request":
            # 伺服器發來的請求剛好用了同一個 id：不能當成回應
            reply({{"id": msg["id"], "method": "item/tool/requestUserInput", "params": {{}}}})
        if MODE == "logged-out":
            reply({{"id": msg["id"], "error": json.load(open(os.path.join(FIXTURES, "logged-out-error.json")))}})
        elif MODE == "error":
            reply({{"id": msg["id"], "error": {{"code": -32603, "message": "boom for person@example.com"}}}})
        else:
            reply({{"id": msg["id"], "result": RESULT}})
if MODE in ("ignore-eof", "ignore-term"):
    time.sleep(60)
'''


class FakeCodex:
    """在臨時資料夾產生假的 codex 執行檔，並把 config.json 的 codex_path 指向它。"""

    def __init__(self, mode: str = "ok", result: dict | None = None):
        self.dir = tempfile.TemporaryDirectory()
        root = Path(self.dir.name)
        self.log = root / "log.jsonl"
        self.path = root / "bin" / "codex"
        self.path.parent.mkdir()
        self.path.write_text(f"#!{sys.executable}\n" + FAKE.format(
            mode=mode, result=RATE_LIMITS if result is None else result, log=str(self.log), fixtures=str(FIXTURES)))
        self.path.chmod(0o755)
        self.config = root / "config.json"
        self.config.write_text(json.dumps({"relay_url": "https://x", "codex_path": str(self.path)}))
        self.patch = mock.patch("usage_collector.paths.CONFIG_PATH", self.config)
        self.saved = None

    def records(self) -> list[dict]:
        if self.saved is not None:  # 臨時資料夾已刪除：用離開時留下的紀錄
            return self.saved
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def pids(self) -> list[int]:
        return [r[k] for r in self.records() for k in ("pid", "child") if k in r]

    def __enter__(self):
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()
        self.saved = self.records()
        self.dir.cleanup()


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class CodexParseTest(unittest.TestCase):
    def test_parses_recorded_response(self):
        usage = codex.parse(RATE_LIMITS).to_dict()
        self.assertEqual(usage, {"plan": "Team", "error": None, "windows": [
            {"id": "five_hour", "label": "5 小時", "used_pct": 0.0, "resets_at": "2026-10-21T22:48:15Z", "hidden": False},
            {"id": "weekly", "label": "每週", "used_pct": 8.0, "resets_at": "2026-10-27T09:45:10Z", "hidden": False},
        ]})

    def test_personal_data_is_not_kept(self):
        text = json.dumps(codex.parse(RATE_LIMITS).to_dict())
        for field in ("00000000", "accountId", "credits", "balance"):
            self.assertNotIn(field, text)

    def test_missing_window_is_skipped(self):
        result = json.loads(json.dumps(RATE_LIMITS))
        result["rateLimits"]["primary"] = None
        self.assertEqual([w.id for w in codex.parse(result).windows], ["weekly"])

    def test_other_window_lengths(self):
        for minutes, wid in ((1440, "24h"), (90, "90m")):
            result = {"rateLimits": {"primary": {"usedPercent": 1, "windowDurationMins": minutes}}}
            with self.subTest(minutes=minutes):
                self.assertEqual(codex.parse(result).windows[0].id, wid)

    def test_plan_names(self):
        for plan, name in (("pro", "Pro"), ("edu_plus", "Edu Plus"), ("prolite", "Prolite"), ("unknown", None),
                           (None, None), (3, None), ("Bad Plan!", None), ("a" * 40, None)):
            with self.subTest(plan=plan):
                self.assertEqual(codex.plan_name(plan), name)

    def test_format_changed_is_error_not_zero(self):
        bad_results = [
            {},  # 沒有 rateLimits
            {"rateLimits": None},
            {"rateLimits": []},
            {"rateLimits": {"primary": "50%"}},
            {"rateLimits": {"primary": {"usedPercent": 5}}},  # 沒有長度：不知道是哪個額度
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": "300"}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 0}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": True}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": "soon"}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 10 ** 20}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": -1}}},
            # 太長的額度：不輸出（window id 也會超過中繼的 64 字上限，讓整份快照被拒收）
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 60 * 10 ** 70}}},
            {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300},
                            "secondary": {"usedPercent": 6, "windowDurationMins": 300}}},  # 重複
        ]
        for result in bad_results:
            with self.subTest(result=result), self.assertRaisesRegex(ProviderError, "格式已改變"):
                codex.parse(result)

    def test_zero_reset_means_no_reset_time(self):
        # 舊端點的 0 是「沒有重置時間」，不能變成 1970-01-01
        result = {"rateLimits": {"primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 0}}}
        self.assertIsNone(codex.parse(result).windows[0].resets_at)

    def test_no_windows_is_error(self):
        with self.assertRaisesRegex(ProviderError, "沒有用量資料"):
            codex.parse({"rateLimits": {"primary": None, "secondary": None, "planType": "pro"}})


# C-04：百分比缺少或格式不對時要報錯，不能變成「0% 已用」
BAD_PERCENTS = [None, "12", float("nan"), float("inf"), -5, True, 10 ** 400, 1001]


class PercentValidationTest(unittest.TestCase):
    def test_missing_percent(self):
        with self.assertRaises(ProviderError):
            codex.parse({"rateLimits": {"primary": {"windowDurationMins": 300, "resetsAt": 1792529816}}})

    def test_bad_percent(self):
        for value in BAD_PERCENTS:
            result = {"rateLimits": {"primary": {"usedPercent": value, "windowDurationMins": 300}}}
            with self.subTest(value=value), self.assertRaises(ProviderError):
                codex.parse(result)

    def test_zero_and_over_limit_are_kept(self):
        # 0 是真的沒用；超過 100（超額）照實傳出，顯示端會限制在 0～100
        result = {"rateLimits": {
            "primary": {"usedPercent": 0, "windowDurationMins": 300},
            "secondary": {"usedPercent": 104, "windowDurationMins": 10080},
        }}
        self.assertEqual([w.used_pct for w in codex.parse(result).windows], [0.0, 104.0])


class CodexFetchTest(unittest.TestCase):
    def assert_no_leftover(self, fake: FakeCodex):
        pids = fake.pids()
        self.assertTrue(pids)
        deadline = time.monotonic() + 3  # 被 SIGKILL 的孫程序要等 launchd 收掉
        while any(alive(p) for p in pids) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual([p for p in pids if alive(p)], [])

    def test_fetch_runs_app_server(self):
        with FakeCodex() as fake:
            usage = codex.fetch()
            records = fake.records()
        self.assertEqual(usage.plan, "Team")
        self.assertEqual([w.id for w in usage.windows], ["five_hour", "weekly"])
        sent = [r["received"] for r in records if "received" in r]
        self.assertEqual([m.get("method") for m in sent], ["initialize", "initialized", "account/rateLimits/read"])
        self.assertEqual(sent[0]["params"]["clientInfo"]["name"], "ai_usage_monitor")
        # 在暫存資料夾執行；codex 所在的資料夾放在 PATH 最前面（npm 版要找得到 node）
        self.assertIn("aum-codex-", records[0]["cwd"])
        self.assertEqual(records[0]["path"].split(os.pathsep)[0], str(fake.path.parent))
        self.assert_no_leftover(fake)

    def test_personal_data_stays_out_of_snapshot_and_log(self):
        out, err = io.StringIO(), io.StringIO()
        with FakeCodex(mode="error"), mock.patch.object(cli, "enabled_providers", return_value=["codex"]), \
             redirect_stdout(out), redirect_stderr(err):
            code = cli.main(["--compact"])
        self.assertEqual(code, 1)
        self.assertIn("codex: Codex app-server 查詢額度失敗（代碼 -32603）", err.getvalue())
        with FakeCodex():
            snapshot = json.dumps(cli.collect(["codex"]))
        for text in (out.getvalue(), err.getvalue(), snapshot):
            for secret in ("person@example.com", "@", "secret", "00000000", "example-mac", "/Users/example"):
                self.assertNotIn(secret, text)

    def test_logged_out(self):
        with FakeCodex(mode="logged-out") as fake, self.assertRaisesRegex(ProviderError, "尚未登入 Codex CLI"):
            codex.fetch()
        self.assert_no_leftover(fake)

    def test_server_request_with_same_id_is_not_a_response(self):
        with FakeCodex(mode="server-request"):
            self.assertEqual(len(codex.fetch().windows), 2)

    def test_garbage_output_is_format_change(self):
        with FakeCodex(mode="garbage") as fake, self.assertRaises(ProviderError) as ctx:
            codex.fetch()
        self.assertIn("格式已改變", str(ctx.exception))
        self.assertNotIn("@", str(ctx.exception))
        self.assert_no_leftover(fake)

    def test_output_is_bounded(self):
        with FakeCodex(mode="flood") as fake, mock.patch.object(codex, "MAX_OUTPUT", 256 * 1024), \
             self.assertRaisesRegex(ProviderError, "格式已改變"):
            codex.fetch()
        self.assert_no_leftover(fake)

    def test_unexpected_exit(self):
        with FakeCodex(mode="exit") as fake, self.assertRaisesRegex(ProviderError, "意外結束"):
            codex.fetch()
        self.assert_no_leftover(fake)

    def test_timeout_closes_app_server(self):
        with FakeCodex(mode="hang") as fake, mock.patch.object(codex, "TIMEOUT", 0.5), \
             self.assertRaisesRegex(ProviderError, "逾時"):
            codex.fetch()
        self.assert_no_leftover(fake)

    def test_app_server_ignoring_eof_is_killed_with_its_children(self):
        for mode in ("ignore-eof", "ignore-term"):  # 後者連 SIGTERM 都不理，要用 SIGKILL
            with self.subTest(mode=mode), FakeCodex(mode=mode) as fake, \
                 mock.patch.object(codex, "CLOSE_TIMEOUT", 0.3):
                started = time.monotonic()
                self.assertEqual(len(codex.fetch().windows), 2)
                self.assertLess(time.monotonic() - started, 5)
                self.assert_no_leftover(fake)

    def test_interrupt_still_closes_app_server(self):
        # 收集器被中斷（Ctrl-C；launchd 的 SIGTERM 在 __main__ 轉成 SystemExit）時同樣關閉
        with FakeCodex(mode="hang") as fake, \
             mock.patch.object(codex.AppServer, "read_message", side_effect=KeyboardInterrupt), \
             self.assertRaises(KeyboardInterrupt):
            codex.fetch()
        self.assert_no_leftover(fake)

    def test_close_survives_zombie_process_group(self):
        # app-server 在等待逾時之後、killpg 之前結束：macOS 對只剩殭屍的 group 回 EPERM，
        # 不能讓它蓋掉已經拿到的結果，也要確實收掉程序
        real_wait = subprocess.Popen.wait
        state = {"first": True}

        def flaky_wait(proc, timeout=None):
            if state["first"]:
                state["first"] = False
                # 等它結束但不收掉，留下殭屍（macOS 沒有 os.waitid，看 ps 的狀態）
                while subprocess.run(["ps", "-o", "stat=", "-p", str(proc.pid)],
                                     capture_output=True, text=True).stdout.strip()[:1] != "Z":
                    time.sleep(0.02)
                raise subprocess.TimeoutExpired(proc.args, timeout)
            return real_wait(proc, timeout)

        with FakeCodex() as fake, mock.patch.object(subprocess.Popen, "wait", flaky_wait):
            usage = codex.fetch()
        self.assertFalse(state["first"])
        self.assertEqual(usage.plan, "Team")
        self.assert_no_leftover(fake)

    def test_cleanup_error_does_not_hide_original_error(self):
        with FakeCodex(mode="logged-out"), \
             mock.patch.object(codex.os, "killpg", side_effect=RuntimeError("cleanup")), \
             mock.patch.object(codex, "CLOSE_TIMEOUT", 0.01), \
             mock.patch.object(subprocess.Popen, "wait", side_effect=subprocess.TimeoutExpired("codex", 0)), \
             self.assertRaisesRegex(ProviderError, "尚未登入"):
            try:
                codex.fetch()
            finally:
                mock.patch.stopall()

    def test_codex_not_found(self):
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"codex_path": str(Path(d) / "missing")}))
            with mock.patch("usage_collector.paths.CONFIG_PATH", config), \
                 mock.patch.dict(os.environ, {"PATH": d}), mock.patch.object(codex, "FALLBACK_PATHS", ()), \
                 self.assertRaisesRegex(ProviderError, "找不到 codex"):
                codex.fetch()

    def test_does_not_touch_codex_credentials(self):
        # 收集器的程式碼中不出現 auth.json、token 欄位與用量端點（ADR-0007）
        source = "\n".join(p.read_text() for p in Path(codex.__file__).parents[1].rglob("*.py"))
        for needle in ("auth.json", "access_token", "refresh_token", "id_token", "chatgpt.com", "wham",
                       "api.anthropic.com", "Claude Code-credentials"):
            self.assertNotIn(needle, source)


class ResolveCodexPathTest(unittest.TestCase):
    def test_config_then_path_then_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "codex"
            exe.write_text("#!/bin/sh\n")
            exe.chmod(0o755)
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"codex_path": str(exe)}))
            self.assertEqual(codex.resolve_codex_path(config), str(exe))
            config.write_text(json.dumps({"codex_path": ["not", "a", "string"]}))
            with mock.patch.dict(os.environ, {"PATH": d}):
                self.assertEqual(codex.resolve_codex_path(config), str(exe))
            with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}), \
                 mock.patch.object(codex, "FALLBACK_PATHS", (str(exe),)):
                self.assertEqual(codex.resolve_codex_path(Path(d) / "missing.json"), str(exe))
            with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}), mock.patch.object(codex, "FALLBACK_PATHS", ()):
                self.assertIsNone(codex.resolve_codex_path(Path(d) / "missing.json"))
            # 相對路徑轉成絕對路徑：provider 在暫存資料夾執行
            config.write_text(json.dumps({"codex_path": "codex"}))
            cwd = os.getcwd()
            try:
                os.chdir(d)
                resolved = codex.resolve_codex_path(config)
                self.assertTrue(os.path.isabs(resolved))
                self.assertEqual(os.path.realpath(resolved), os.path.realpath(exe))
            finally:
                os.chdir(cwd)


if __name__ == "__main__":
    unittest.main()
