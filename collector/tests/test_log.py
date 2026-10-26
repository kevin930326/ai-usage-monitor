"""日誌輪替（ADR-0014）：每份最多 1 MB、留一份舊的；Windows 的 --log-file、App 內建收集器與 launchd 開好的 stderr 三種寫法。"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

from usage_collector import log as log_module

COLLECTOR = Path(__file__).resolve().parents[1]


def child(code: str, stdout, stderr) -> subprocess.CompletedProcess:
    """另開一個 Python 執行 `code`（要改 fd 1、2，不能在測試程序裡做）"""
    return subprocess.run([sys.executable, "-c", textwrap.dedent(code)], cwd=COLLECTOR, stdout=stdout, stderr=stderr,
                          env={**os.environ, "PYTHONPATH": str(COLLECTOR)}, timeout=30)


class RotateIfLargeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "collector.log"

    def test_small_or_missing_file_is_kept(self):
        self.assertFalse(log_module.rotate_if_large(self.path))
        self.path.write_text("a" * 100)
        self.assertFalse(log_module.rotate_if_large(self.path, limit=100))
        self.assertEqual(self.path.read_text(), "a" * 100)
        self.assertFalse(self.path.with_name("collector.log.1").exists())

    def test_large_file_replaces_the_previous_old_copy(self):
        old = self.path.with_name("collector.log.1")
        old.write_text("older")
        self.path.write_text("b" * 101)
        self.assertTrue(log_module.rotate_if_large(self.path, limit=100))
        self.assertFalse(self.path.exists())
        self.assertEqual(old.read_text(), "b" * 101)  # 只留一份舊的

    def test_default_limit_is_one_megabyte(self):
        self.path.write_bytes(b"x" * 1_000_000)
        self.assertFalse(log_module.rotate_if_large(self.path))
        self.path.write_bytes(b"x" * 1_000_001)
        self.assertTrue(log_module.rotate_if_large(self.path))

    def test_rename_failure_keeps_appending(self):
        # Windows：別的程序開著日誌時 os.replace 失敗 → 不輪替、不中斷收集
        self.path.write_text("c" * 200)
        with mock.patch.object(log_module.os, "replace", side_effect=PermissionError):
            self.assertFalse(log_module.rotate_if_large(self.path, limit=100))
        self.assertEqual(self.path.read_text(), "c" * 200)

    def test_another_collector_rotating_in_between_keeps_the_full_old_copy(self):
        """量完大小、改名之前另一個收集器先輪替了（審查 C-02）：不能拿它新建的短檔蓋掉剛存好的 .1。"""
        self.path.write_text("full log\n" * 30)
        old = self.path.with_name("collector.log.1")
        real_stat = Path.stat
        raced = []

        def racing_stat(p, *args, **kwargs):
            st = real_stat(p, *args, **kwargs)
            if p == self.path and not raced:
                raced.append(True)
                os.replace(self.path, old)  # 另一個收集器輪替
                self.path.write_text("new\n")
            return st
        with mock.patch.object(Path, "stat", racing_stat):
            self.assertFalse(log_module.rotate_if_large(self.path, limit=100))
        self.assertTrue(old.read_text().startswith("full log"))
        self.assertEqual(self.path.read_text(), "new\n")


@unittest.skipIf(sys.platform == "win32", "launchd 只在 macOS；Windows 不能改名開著的檔案，改用 --log-file")
class RotateInheritedTest(unittest.TestCase):
    """install-launchd.sh 的收集器：launchd 先把 stdout／stderr 開成附加到 collector.log 才啟動"""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.path = self.dir / "collector.log"

    def run_child(self, stderr_path: Path) -> subprocess.CompletedProcess:
        code = f"""
            import sys
            from pathlib import Path
            from usage_collector.log import log, rotate_inherited
            rotated = rotate_inherited(Path({str(self.path)!r}), limit=100)
            log(f"after rotated={{rotated}}")
            print("stdout line")
        """
        with open(stderr_path, "a") as f:
            return child(code, stdout=f, stderr=f)

    def test_large_inherited_log_moves_to_old_copy_and_new_lines_go_to_a_new_file(self):
        self.path.write_text("old line\n" * 20)
        result = self.run_child(self.path)
        self.assertEqual(result.returncode, 0)
        old = self.path.with_name("collector.log.1").read_text()
        new = self.path.read_text()
        self.assertTrue(old.startswith("old line"))
        self.assertNotIn("after", old)
        self.assertIn("after rotated=True", new)
        self.assertIn("stdout line", new)  # StandardOutPath 是同一個檔案，也要換過去
        self.assertNotIn("old line", new)

    def test_reopen_failure_keeps_logging_to_the_old_descriptor(self):
        """改名後開不了新檔（磁碟滿）：沿用原本的描述元（指向 .1），不中斷收集（審查 C-01）。"""
        self.path.write_text("old line\n" * 20)
        code = f"""
            import os, sys
            from pathlib import Path
            from usage_collector import log as L
            real_open = os.open
            def failing(path, *a, **k):
                if str(path) == {str(self.path)!r}:
                    raise OSError(28, "No space left on device")
                return real_open(path, *a, **k)
            L.os.open = failing
            rotated = L.rotate_inherited(Path({str(self.path)!r}), limit=100)
            L.log(f"after rotated={{rotated}}")
        """
        with open(self.path, "a") as f:
            result = child(code, stdout=f, stderr=f)
        self.assertEqual(result.returncode, 0)
        old = self.path.with_name("collector.log.1").read_text()
        self.assertIn("after rotated=False", old)
        self.assertNotIn("Traceback", old)

    def test_small_log_is_not_rotated(self):
        self.path.write_text("x\n")
        self.run_child(self.path)
        self.assertFalse(self.path.with_name("collector.log.1").exists())
        self.assertIn("after rotated=False", self.path.read_text())

    def test_stderr_elsewhere_is_left_alone(self):
        # 手動執行（stderr 是終端機或別的檔案）時不動 launchd 的日誌
        self.path.write_text("old line\n" * 20)
        other = self.dir / "other.log"
        self.run_child(other)
        self.assertFalse(self.path.with_name("collector.log.1").exists())
        self.assertIn("after rotated=False", other.read_text())


class MainRotatesTest(unittest.TestCase):
    def test_log_file_and_app_agent_rotate_before_opening(self):
        with tempfile.TemporaryDirectory() as d:
            for how in ("log-file", "app-agent"):
                path = Path(d) / how / "collector.log"
                path.parent.mkdir()
                path.write_bytes(b"o" * 1_000_001)
                if how == "log-file":
                    code = f"""
                        import sys
                        from usage_collector.log import log, rotate_if_large
                        from pathlib import Path
                        p = Path({str(path)!r})
                        rotate_if_large(p)
                        sys.stderr = open(p, "a", encoding="utf-8", buffering=1)
                        log("new run")
                    """
                else:
                    code = f"""
                        from pathlib import Path
                        from usage_collector.__main__ import redirect_stderr_to
                        from usage_collector.log import log
                        redirect_stderr_to(Path({str(path)!r}))
                        log("new run")
                    """
                result = child(code, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.with_name("collector.log.1").stat().st_size, 1_000_001, how)
                self.assertIn("new run", path.read_text(encoding="utf-8"), how)
                self.assertLess(path.stat().st_size, 200, how)

    def test_main_rotates_the_log_file_argument(self):
        from usage_collector import __main__ as main_module
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "collector.log"
            path.write_bytes(b"o" * 1_000_001)
            saved = sys.stderr
            try:
                with mock.patch.object(main_module.token_stats, "run_safely", return_value=True), \
                        mock.patch.object(main_module.history, "tidy_safely"), \
                        mock.patch.object(main_module.token_sync, "run_safely"):
                    self.assertEqual(main_module.main(["--tokens-only", "--quiet", "--log-file", str(path)]), 0)
            finally:
                if sys.stderr is not saved:
                    sys.stderr.close()
                sys.stderr = saved
            self.assertTrue(path.with_name("collector.log.1").exists())
            self.assertLess(path.stat().st_size, 1000)


class LimitRepeatsTest(unittest.TestCase):
    """相同的一行連續出現時每小時一行、不再出現時一行「已恢復」（ADR-0014 LT-02 後續）。每一輪是一個 limit_repeats"""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state = log_module.repeats_path(Path(tmp.name) / "collector.log")
        self.now = 1_800_000_000

    def run_round(self, *messages: str, minutes: int = 5) -> list[str]:
        """一輪收集：記錄 messages，回傳實際寫出的行（去掉時間）"""
        self.now += minutes * 60
        lines: list[str] = []
        with mock.patch.object(log_module.time, "time", return_value=self.now), \
                mock.patch.object(log_module, "_write", side_effect=lines.append):
            with log_module.limit_repeats(self.state):
                for message in messages:
                    log_module.log(message)
        return lines

    def test_same_error_every_round_is_written_once_an_hour(self):
        written = [self.run_round("claude: 未登入") for _ in range(25)]  # 每 5 分鐘一輪，2 小時
        self.assertEqual(written[0], ["claude: 未登入"])
        self.assertTrue(all(lines == [] for lines in written[1:12]))
        self.assertEqual(written[12], ["claude: 未登入（仍在發生，已持續 1 小時，期間略過 11 次）"])
        self.assertTrue(all(lines == [] for lines in written[13:24]))
        self.assertEqual(written[24], ["claude: 未登入（仍在發生，已持續 2 小時，期間略過 11 次）"])

    def test_recovery_is_written_once(self):
        self.run_round("codex: 逾時")
        self.run_round("codex: 逾時")
        self.run_round("codex: 逾時")
        self.assertEqual(self.run_round(), ["已恢復：codex: 逾時（持續 10 分鐘）"])
        self.assertEqual(self.run_round(), [])
        self.assertFalse(self.state.exists())
        # 之後再出現是新的一次，照常記錄
        self.assertEqual(self.run_round("codex: 逾時"), ["codex: 逾時"])

    def test_a_line_seen_once_has_no_recovery_line(self):
        self.run_round("整理 history.sqlite3：3.0 MB → 2.0 MB")
        self.assertEqual(self.run_round(), [])

    def test_different_messages_are_tracked_separately(self):
        self.assertEqual(self.run_round("a", "b"), ["a", "b"])
        self.assertEqual(self.run_round("a", "c"), ["c"])
        # b、c 都只出現過一輪：不記「已恢復」
        self.assertEqual(self.run_round("a"), [])
        self.assertEqual(self.run_round(), ["已恢復：a（持續 10 分鐘）"])

    def test_the_same_line_twice_in_one_round_is_written_once(self):
        self.assertEqual(self.run_round("x", "x"), ["x"])
        self.assertEqual(self.run_round("x", "x"), [])

    def test_unreadable_or_broken_state_logs_normally(self):
        self.state.write_text("{not json")
        self.assertEqual(self.run_round("x"), ["x"])
        self.state.write_text('{"x": {"first": "a"}}')
        self.assertEqual(self.run_round("x"), ["x"])

    def test_clock_going_back_logs_again(self):
        self.run_round("x")
        self.assertEqual(self.run_round("x", minutes=-60), ["x"])

    def test_state_keeps_at_most_the_most_recent_messages(self):
        many = [f"錯誤 {i}" for i in range(log_module.REPEAT_MAX_TRACKED + 10)]
        self.run_round(*many)
        self.assertEqual(len(json.loads(self.state.read_text(encoding="utf-8"))), log_module.REPEAT_MAX_TRACKED)

    def test_two_rounds_finishing_together_do_not_take_each_others_temp_file(self):
        # 兩個程序（手動執行與排程用同一個 --log-file）各自寫暫存檔再替換：都成功，後寫的留下
        rounds = []
        for message in ("a", "b"):
            r = log_module._Repeats(self.state)
            r.filter(message, self.now)
            rounds.append(r)
        replaced = []
        real_replace = os.replace

        def replace(a, b):
            replaced.append(Path(a).name)
            real_replace(a, b)

        with mock.patch.object(log_module.os, "replace", side_effect=replace), \
                mock.patch.object(log_module.os, "getpid", side_effect=[101, 202]):
            for r in rounds:
                r.finish(self.now)
        self.assertEqual(len(set(replaced)), 2)
        self.assertEqual(list(json.loads(self.state.read_text(encoding="utf-8"))), ["b"])
        self.assertEqual([p.name for p in self.state.parent.glob("*.tmp")], [])

    @unittest.skipIf(sys.platform == "win32", "Windows 沒有 POSIX 權限")
    def test_state_file_is_private(self):
        old = os.umask(0o022)
        try:
            self.run_round("x")
        finally:
            os.umask(old)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_without_a_state_file_every_line_is_written(self):
        lines: list[str] = []
        with mock.patch.object(log_module, "_write", side_effect=lines.append):
            with log_module.limit_repeats(None):
                log_module.log("x")
                log_module.log("x")
            log_module.log("x")
        self.assertEqual(lines, ["x", "x", "x"])


class MainLimitsRepeatsTest(unittest.TestCase):
    def test_log_file_runs_share_the_state_next_to_the_log(self):
        from usage_collector import __main__ as main_module
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "collector.log"
            saved = sys.stderr
            try:
                with mock.patch.object(main_module.token_stats, "run_safely",
                                       side_effect=lambda: main_module.log("略過 Token 統計：OperationalError") or False), \
                        mock.patch.object(main_module.history, "tidy_safely"), \
                        mock.patch.object(main_module.token_sync, "run_safely"):
                    for _ in range(3):
                        self.assertEqual(main_module.main(["--tokens-only", "--quiet", "--log-file", str(path)]), 1)
                        if sys.stderr is not saved:
                            sys.stderr.close()
                        sys.stderr = saved
            finally:
                if sys.stderr is not saved:
                    sys.stderr.close()
                sys.stderr = saved
            self.assertEqual(path.read_text(encoding="utf-8").count("略過 Token 統計"), 1)
            self.assertTrue(log_module.repeats_path(path).exists())

    def test_app_agent_and_legacy_collector_keep_separate_state(self):
        log_path = Path("/x/collector.log")
        self.assertNotEqual(log_module.repeats_path(log_path), log_module.repeats_path(log_path, "app"))


if __name__ == "__main__":
    unittest.main()
