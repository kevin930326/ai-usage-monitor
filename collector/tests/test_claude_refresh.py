import io
import json
import os
import tempfile
import time
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from usage_collector import claude_refresh as cr
from usage_collector.models import ProviderError
from usage_collector.providers import claude

NOW = 1_800_000_000.0
EXPIRED = {"accessToken": "old", "expiresAt": int((NOW - 60) * 1000)}
EXPIRING = {"accessToken": "old", "expiresAt": int((NOW + 120) * 1000)}
VALID = {"accessToken": "new", "expiresAt": int((NOW + 8 * 3600) * 1000)}


class FakeClaude:
    """在臨時資料夾產生假的 claude 執行檔；成功時寫一個標記檔，代表 Claude Code 已把新 token 寫回 Keychain。"""

    def __init__(self, tmp: Path, body: str):
        self.marker = tmp / "refreshed"
        self.path = tmp / "claude"
        self.path.write_text(f"#!/bin/bash\n{body}\n")
        self.path.chmod(0o755)

    def reload(self) -> dict:
        return dict(VALID) if self.marker.exists() else dict(EXPIRED)


class RefreshTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state_path = self.tmp / "state.json"
        self.notifications = []
        self.addCleanup(self._tmp.cleanup)

    def ensure(self, oauth, fake=None, now=NOW, run=cr.run_claude, reload=None, claude_path=None):
        path = claude_path if claude_path is not None else (str(fake.path) if fake else None)
        with redirect_stderr(io.StringIO()) as err:
            try:
                return cr.ensure_fresh(oauth, reload or fake.reload, now=now, claude_path=path,
                                       state_path=self.state_path, run=run,
                                       send_notification=self.notifications.append)
            finally:
                self.log = err.getvalue()

    def state(self) -> dict:
        return json.loads(self.state_path.read_text())


class FakeExecutableTest(RefreshTestCase):
    def test_success_rereads_credentials(self):
        # cat 會一直讀到 stdin 結束：stdin 沒關閉的話這裡會卡到逾時
        fake = FakeClaude(self.tmp, f'cat >/dev/null; printf "%s\\n" "$PWD" "$*" > "{self.tmp}/refreshed"')
        self.assertEqual(self.ensure(EXPIRED, fake), VALID)
        cwd, args = fake.marker.read_text().splitlines()
        self.assertEqual(args, "-p /usage --safe-mode --no-session-persistence")
        self.assertNotEqual(Path(cwd).resolve(), Path.cwd().resolve())  # 在暫存資料夾執行
        self.assertIn("completed", self.log)
        self.assertNotIn("failing_since", self.state())

    def test_failure_raises_and_records(self):
        fake = FakeClaude(self.tmp, "echo boom >&2; exit 1")
        with self.assertRaisesRegex(ProviderError, "開一次 Claude Code"):
            self.ensure(EXPIRED, fake)
        self.assertIn("failed", self.log)
        self.assertNotIn("boom", self.log)  # claude 的輸出不進日誌
        self.assertEqual(self.state()["failing_since"], NOW)

    def test_timeout(self):
        fake = FakeClaude(self.tmp, "sleep 10")
        started = time.monotonic()
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, fake, run=lambda p: cr.run_claude(p, timeout=0.5))
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn("timed_out", self.log)

    def test_missing_executable_counts_as_failure(self):
        self.assertEqual(cr.run_claude(str(self.tmp / "nope")), "failed")


class PolicyTest(RefreshTestCase):
    def test_valid_token_does_not_run_claude(self):
        run = mock.Mock()
        self.assertEqual(self.ensure(VALID, run=run, reload=mock.Mock(), claude_path="/x"), VALID)
        run.assert_not_called()
        self.assertFalse(self.state_path.exists())  # 平常不寫狀態檔

    def test_expiring_token_is_refreshed_early(self):
        run = mock.Mock(return_value="completed")
        self.assertEqual(self.ensure(EXPIRING, run=run, reload=lambda: dict(VALID), claude_path="/x"), VALID)
        run.assert_called_once_with("/x")

    def test_expiring_token_still_usable_when_refresh_fails(self):
        run = mock.Mock(return_value="failed")
        self.assertEqual(self.ensure(EXPIRING, run=run, reload=lambda: dict(EXPIRING), claude_path="/x"), EXPIRING)

    def test_attempts_are_throttled_to_every_30_minutes(self):
        run = mock.Mock(return_value="failed")
        reload = lambda: dict(EXPIRED)
        for minutes in (0, 5, 29):
            with self.assertRaises(ProviderError):
                self.ensure(EXPIRED, run=run, reload=reload, claude_path="/x", now=NOW + minutes * 60)
        self.assertEqual(run.call_count, 1)
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, run=run, reload=reload, claude_path="/x", now=NOW + 30 * 60)
        self.assertEqual(run.call_count, 2)

    def test_no_claude_path_skips_but_still_throttles_log(self):
        reload = mock.Mock()
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, reload=reload, claude_path="")
        self.assertIn("找不到 claude", self.log)
        reload.assert_not_called()
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, reload=reload, claude_path="", now=NOW + 300)
        self.assertEqual(self.log, "")

    def test_notifies_once_after_30_minutes_of_failure(self):
        run = mock.Mock(return_value="failed")
        reload = lambda: dict(EXPIRED)
        for minutes in (0, 10, 29, 30, 35, 60, 90):
            with self.assertRaises(ProviderError):
                self.ensure(EXPIRED, run=run, reload=reload, claude_path="/x", now=NOW + minutes * 60)
            self.assertEqual(len(self.notifications), 0 if minutes < 30 else 1, minutes)

    def test_new_expiry_after_recovery_notifies_again(self):
        run = mock.Mock(return_value="failed")
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, run=run, reload=lambda: dict(EXPIRED), claude_path="/x")
        with self.assertRaises(ProviderError):
            self.ensure(EXPIRED, run=run, reload=lambda: dict(EXPIRED), claude_path="/x", now=NOW + 1800)
        self.assertEqual(len(self.notifications), 1)
        # 使用者開了 Claude Code，token 恢復 → 失敗紀錄清除
        self.ensure(VALID, run=run, reload=mock.Mock(), claude_path="/x", now=NOW + 2000)
        self.assertNotIn("notified_expires_at", self.state())
        later = NOW + 9 * 3600
        expired_again = {"accessToken": "new", "expiresAt": int((later - 60) * 1000)}
        for offset in (0, 1800):
            with self.assertRaises(ProviderError):
                self.ensure(expired_again, run=run, reload=lambda: dict(expired_again), claude_path="/x",
                            now=later + offset)
        self.assertEqual(len(self.notifications), 2)

    def test_corrupt_state_file_is_ignored(self):
        self.state_path.write_text("not json")
        run = mock.Mock(return_value="completed")
        self.assertEqual(self.ensure(EXPIRED, run=run, reload=lambda: dict(VALID), claude_path="/x"), VALID)


class ResolveClaudePathTest(unittest.TestCase):
    def test_reads_config_and_falls_back_to_path(self):
        with tempfile.TemporaryDirectory() as d:
            exe = Path(d) / "claude"
            exe.write_text("#!/bin/sh\n")
            exe.chmod(0o755)
            config = Path(d) / "config.json"
            config.write_text(json.dumps({"relay_url": "https://x", "claude_path": str(exe)}))
            self.assertEqual(cr.resolve_claude_path(config), str(exe))
            config.write_text(json.dumps({"relay_url": "https://x"}))
            with mock.patch.dict(os.environ, {"PATH": d}):
                self.assertEqual(cr.resolve_claude_path(config), str(exe))
            with mock.patch.dict(os.environ, {"PATH": "/nonexistent"}):
                self.assertIsNone(cr.resolve_claude_path(Path(d) / "missing.json"))


class ClaudeFetchTest(unittest.TestCase):
    def test_fetch_uses_refreshed_token(self):
        with mock.patch.object(claude, "read_credentials", return_value={"accessToken": "t"}), \
             mock.patch.object(claude.claude_refresh, "ensure_fresh", return_value={"accessToken": "fresh"}), \
             mock.patch.object(claude, "get_json", return_value={"five_hour": {"utilization": 1}}) as get:
            claude.fetch()
        self.assertEqual(get.call_args.args[1]["Authorization"], "Bearer fresh")


if __name__ == "__main__":
    unittest.main()
