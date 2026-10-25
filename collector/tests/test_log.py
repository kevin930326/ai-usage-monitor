"""日誌輪替（ADR-0014）：每份最多 1 MB、留一份舊的；Windows 的 --log-file、App 內建收集器與 launchd 開好的 stderr 三種寫法。"""
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


if __name__ == "__main__":
    unittest.main()
