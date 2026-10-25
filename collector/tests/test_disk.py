"""磁碟空間不足的保護（ADR-0014 LT-06、LT-20）：暫停寫 history.sqlite3，usage.json 與上傳照常；殘留暫存檔回收。
剩餘空間以 mock 模擬，不需要真的把磁碟填滿；Windows 同樣以 shutil.disk_usage 讀取。"""
import errno
import io
import json
import os
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector import disk, history, local_store, relay
from usage_collector.models import ProviderUsage, Window

MB = 1024 * 1024
NO_LOGS = {"claude": Path("/nonexistent/claude"), "codex": Path("/nonexistent/codex")}


class FullStream(io.StringIO):
    """日誌所在的磁碟也滿了：每次寫入都丟 ENOSPC"""

    def write(self, s):
        raise OSError(errno.ENOSPC, "No space left on device")


class DiskTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        home = mock.patch.object(disk.paths, "APP_SUPPORT_DIR", self.dir)
        home.start()
        self.addCleanup(home.stop)

    def free(self, mb):
        return mock.patch.object(disk.shutil, "disk_usage", return_value=mock.Mock(free=mb * MB))


class LowSpaceTest(DiskTestCase):
    def test_logs_only_when_the_state_changes(self):
        err = io.StringIO()
        with redirect_stderr(err):
            with self.free(100):
                self.assertEqual(disk.low_space(), 100 * MB)
                self.assertEqual(disk.low_space(), 100 * MB)
            self.assertTrue((self.dir / disk.MARKER).exists())
            with self.free(2000):
                self.assertIsNone(disk.low_space())
                self.assertIsNone(disk.low_space())
        lines = err.getvalue().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("磁碟剩餘空間不足（100 MB）", lines[0])
        self.assertIn("磁碟空間已恢復", lines[1])
        self.assertFalse((self.dir / disk.MARKER).exists())

    def test_unreadable_free_space_counts_as_enough(self):
        with mock.patch.object(disk.shutil, "disk_usage", side_effect=OSError):
            self.assertIsNone(disk.low_space())

    def test_free_bytes_of_a_folder_not_created_yet(self):
        self.assertIsNotNone(disk.free_bytes(self.dir / "not" / "yet"))


class CollectorTest(DiskTestCase):
    def run_cli(self, *args, write_error=None, log_full=False):
        self.usage = self.dir / "usage.json"
        self.history = self.dir / "history.sqlite3"
        providers = {"claude": mock.Mock(fetch=mock.Mock(return_value=ProviderUsage(
            plan="Max", windows=[Window("five_hour", "5 小時", 10, None)])))}
        write = local_store.write_snapshot

        def write_snapshot(s):
            if write_error:
                raise write_error
            return write(s, self.usage)
        err = FullStream() if log_full else io.StringIO()
        with mock.patch.dict(cli.PROVIDERS, providers, clear=True), \
             mock.patch.object(cli, "enabled_providers", return_value=["claude"]), \
             mock.patch.object(cli.local_store, "write_snapshot", side_effect=write_snapshot), \
             mock.patch.object(relay, "upload") as upload, \
             mock.patch.object(history, "HISTORY_PATH", self.history), \
             mock.patch.object(cli.token_stats, "log_dirs", return_value=NO_LOGS), \
             mock.patch.object(cli.token_stats, "run_safely", return_value=True) as tokens, \
             mock.patch.object(cli.token_sync, "run_safely") as sync, \
             mock.patch.object(cli.service_status, "update_safely") as status, \
             redirect_stdout(io.StringIO()), redirect_stderr(err):
            code = cli.main(["--quiet", *args])
        return code, upload, tokens, sync, status, err.getvalue()

    def test_low_disk_pauses_history_but_not_usage_json_or_upload(self):
        with self.free(100):
            code, upload, tokens, sync, status, err = self.run_cli("--write-local", "--upload")
        self.assertEqual(code, 0)
        local = json.loads(self.usage.read_text(encoding="utf-8"))
        self.assertEqual(local["local_status"], {"history_paused": "low_disk", "disk_free_mb": 100})
        upload.assert_called_once()
        self.assertNotIn("local_status", upload.call_args.args[0])  # 只在本機，不上傳
        self.assertFalse(self.history.exists())
        tokens.assert_not_called()
        sync.assert_not_called()
        status.assert_called_once()  # 服務狀態和 usage.json 一樣照常
        self.assertIn("磁碟剩餘空間不足", err)

    def test_enough_space_has_no_local_status(self):
        with self.free(5000):
            code, upload, tokens, _, _, _ = self.run_cli("--write-local", "--upload")
        self.assertEqual(code, 0)
        self.assertNotIn("local_status", json.loads(self.usage.read_text(encoding="utf-8")))
        self.assertTrue(self.history.exists())
        tokens.assert_called_once()

    def test_usage_json_write_failure_still_uploads(self):
        with self.free(5000):
            code, upload, tokens, _, _, err = self.run_cli(
                "--write-local", "--upload", write_error=OSError(errno.ENOSPC, "No space left on device", "/x/usage.json"))
        self.assertEqual(code, 1)
        upload.assert_called_once()
        self.assertIn("無法寫入 usage.json（OSError），照常上傳", err)
        self.assertNotIn("/x/usage.json", err)

    def test_full_log_disk_does_not_stop_the_upload(self):
        """日誌也寫不進去（同一顆滿的磁碟）：狀態轉換與快照失敗的日誌丟掉，上傳照常（審查 C-01）"""
        with self.free(100):
            code, upload, tokens, sync, _, _ = self.run_cli("--write-local", "--upload", log_full=True)
        self.assertEqual(code, 0)
        upload.assert_called_once()
        tokens.assert_not_called()
        sync.assert_not_called()
        with self.free(100):
            code, upload, _, _, _, _ = self.run_cli(
                "--write-local", "--upload", log_full=True,
                write_error=OSError(errno.ENOSPC, "No space left on device", "/x/usage.json"))
        self.assertEqual(code, 1)
        upload.assert_called_once()

    def test_tokens_only_on_low_disk_skips_everything(self):
        with self.free(100):
            code, _, tokens, sync, _, err = self.run_cli("--tokens-only")
        self.assertEqual(code, 1)  # 工作排程器的「上次執行結果」看得出來
        tokens.assert_not_called()
        sync.assert_not_called()
        self.assertIn("磁碟剩餘空間不足", err)


class StaleTempTest(unittest.TestCase):
    def test_old_temp_files_are_removed(self):
        with tempfile.TemporaryDirectory() as d:
            folder = Path(d)
            old = folder / ".usage-abc.json"
            new = folder / ".usage-def.json"
            other = folder / ".service-status-x.json"
            for f in (old, new, other):
                f.write_text("{}")
            past = time.time() - 2 * 86400
            os.utime(old, (past, past))
            os.utime(other, (past, past))
            local_store.write_snapshot({"schema_version": 1}, folder / "usage.json")
            self.assertFalse(old.exists())
            self.assertTrue(new.exists())
            self.assertTrue(other.exists())  # 別的前綴由 service_status 自己清
            self.assertTrue((folder / "usage.json").exists())
            local_store.remove_stale_temp(folder, ".service-status-")
            self.assertFalse(other.exists())


if __name__ == "__main__":
    unittest.main()
