"""scripts/clean-dev.sh 的測試：在暫存資料夾建立假的 repo、DerivedData、模擬器指令與 design/_trash，
不碰真實的建置產物、模擬器、分支或垃圾桶。"""
import os
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OLD = time.time() - 40 * 86400


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], env=env, capture_output=True, text=True, check=True).stdout


class CleanDevTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts" / "clean-dev.sh", self.repo / "scripts" / "clean-dev.sh")
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "init")
        git(self.repo, "branch", "backup/old-123")
        git(self.repo, "branch", "feature/keep")
        for d in ["build/verify", "apple/MacMenuBar/build/Build", "apple/UsageKit/.build/debug"]:
            (self.repo / d).mkdir(parents=True)
            (self.repo / d / "f").write_text("x")
        self.derived = self.tmp / "DerivedData"
        for name, mtime in [("AIUsageMenuBar-old", OLD), ("AIUsageMonitor-new", None), ("OtherApp-old", OLD)]:
            (self.derived / name).mkdir(parents=True)
            if mtime:
                os.utime(self.derived / name, (mtime, mtime))
        self.work = self.tmp / "work"
        trash_dir = self.work / "design" / "_trash"
        trash_dir.mkdir(parents=True)
        (trash_dir / "old.png").write_text("x")
        os.utime(trash_dir / "old.png", (OLD, OLD))
        (trash_dir / "new.png").write_text("x")
        self.trash = self.tmp / "Trash"
        self.simlog = self.tmp / "simctl.log"
        self.simctl = self.tmp / "simctl"
        self.simctl.write_text(textwrap.dedent(f"""\
            #!/bin/bash
            echo "$@" >> {self.simlog}
            if [ "$1" = list ]; then
              echo "-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-17-0 --"
              echo "    iPhone 15 (AAAA) (Shutdown) (unavailable, runtime profile not found)"
            fi
            """))
        self.simctl.chmod(0o755)

    def run_script(self, *args: str, busy: bool | str = False, stdin=subprocess.DEVNULL):
        check = busy if isinstance(busy, str) else ("true" if busy else "false")
        env = {**os.environ, "CLEAN_DEV_WORK": str(self.work), "CLEAN_DEV_DERIVED": str(self.derived),
               "CLEAN_DEV_TRASH": str(self.trash), "CLEAN_DEV_SIMCTL": str(self.simctl),
               "CLEAN_DEV_BUSY_CHECK": check, "LANG": "en_US.UTF-8"}
        return subprocess.run(["/bin/bash", str(self.repo / "scripts" / "clean-dev.sh"), *args], env=env,
                              stdin=stdin, capture_output=True, text=True)

    def branches(self) -> list[str]:
        return git(self.repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/").split()

    def test_default_only_lists(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        for expected in ["build", "AIUsageMenuBar-old", "iPhone 15", "backup/old-123", "old.png", "只列出、沒有刪除"]:
            self.assertIn(expected, out)
        # 新的 DerivedData、別的 App、新的 _trash 項目不列
        for unexpected in ["AIUsageMonitor-new", "OtherApp-old", "new.png"]:
            self.assertNotIn(unexpected, out)
        # 沒有刪任何東西
        self.assertTrue((self.repo / "build").exists())
        self.assertTrue((self.derived / "AIUsageMenuBar-old").exists())
        self.assertIn("backup/old-123", self.branches())
        self.assertTrue((self.work / "design" / "_trash" / "old.png").exists())
        self.assertNotIn("delete", self.simlog.read_text())

    def test_clean_yes_removes_only_old_and_regenerable(self):
        result = self.run_script("--clean", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        for gone in ["build", "apple/MacMenuBar/build", "apple/UsageKit/.build"]:
            self.assertFalse((self.repo / gone).exists(), gone)
        self.assertFalse((self.derived / "AIUsageMenuBar-old").exists())
        self.assertTrue((self.derived / "AIUsageMonitor-new").exists())
        self.assertTrue((self.derived / "OtherApp-old").exists())
        self.assertIn("delete unavailable", self.simlog.read_text())
        self.assertEqual(sorted(self.branches()), ["feature/keep", "main"])
        # _trash 的舊項目移到垃圾桶，不是直接刪除；新的留著
        self.assertFalse((self.work / "design" / "_trash" / "old.png").exists())
        self.assertTrue((self.work / "design" / "_trash" / "new.png").exists())
        self.assertEqual(len(list(self.trash.glob("old.png-clean-dev-*"))), 1)

    def test_busy_xcodebuild_keeps_build_products(self):
        result = self.run_script("--clean", "--yes", busy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("建置正在執行", result.stdout)
        self.assertTrue((self.repo / "build").exists())
        self.assertTrue((self.derived / "AIUsageMenuBar-old").exists())
        # 其他類別照常
        self.assertNotIn("backup/old-123", self.branches())

    def test_install_lock_skips_that_build_folder(self):
        (self.repo / "build" / "install.lock").mkdir()
        result = self.run_script("--clean", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo / "build").exists())
        self.assertFalse((self.repo / "apple/MacMenuBar/build").exists())

    def test_build_started_after_listing_keeps_products(self):
        """列出之後、刪除之前開始建置（等待回答的期間）：建置產物與 DerivedData 都留著（審查 C-01）。"""
        calls = self.tmp / "busy-calls"
        check = self.tmp / "busy"
        check.write_text(f"#!/bin/bash\necho x >> {calls}\n[ $(wc -l < {calls}) -gt 1 ]\n")
        check.chmod(0o755)
        result = self.run_script("--clean", "--yes", busy=str(check))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("剛開始執行", result.stdout)
        self.assertTrue((self.repo / "build").exists())
        self.assertTrue((self.derived / "AIUsageMenuBar-old").exists())

    def test_install_lock_created_after_listing_is_respected(self):
        """列出之後才出現的 install.lock：那個 build/ 不刪（審查 C-01）。"""
        calls = self.tmp / "lock-calls"
        check = self.tmp / "lock-then-idle"
        # 第一次（列出前）沒有鎖；第二次（刪除前的再確認）時 install-mac-app.sh 剛建立鎖
        check.write_text(f"#!/bin/bash\necho x >> {calls}\n"
                         f"[ $(wc -l < {calls}) -gt 1 ] && mkdir -p {self.repo}/build/install.lock\nexit 1\n")
        check.chmod(0o755)
        result = self.run_script("--clean", "--yes", busy=str(check))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("略過", result.stdout)
        self.assertTrue((self.repo / "build" / "install.lock").exists())
        self.assertFalse((self.repo / "apple/MacMenuBar/build").exists())

    def test_default_busy_check_covers_swift_package_builds(self):
        """沒有 xcodebuild、只有 swift test 時也算建置中（審查 C-02）：預設的檢查包含 swift-build、swift-test。"""
        text = (self.repo / "scripts" / "clean-dev.sh").read_text(encoding="utf-8")
        self.assertIn("pgrep -x xcodebuild|swift-build|swift-test", text)
        names = subprocess.run(["pgrep", "-x", "xcodebuild|swift-build|swift-test|zsh|bash"], capture_output=True, text=True)
        self.assertEqual(names.returncode, 0)  # pgrep 接受以 | 分隔的名稱（這個測試本身在 bash 底下）

    def test_derived_data_with_recent_files_inside_is_kept(self):
        """最外層資料夾是 40 天前、裡面今天更新過的 DerivedData 不算舊的（審查 C-03）。"""
        busy = self.derived / "AIUsageWatch-busy"
        (busy / "Build" / "Intermediates").mkdir(parents=True)
        (busy / "Build" / "Intermediates" / "today.o").write_text("x")
        for p in (busy / "Build" / "Intermediates", busy / "Build", busy):
            os.utime(p, (OLD, OLD))
        listed = self.run_script()
        self.assertNotIn("AIUsageWatch-busy", listed.stdout)
        self.assertIn("AIUsageMenuBar-old", listed.stdout)
        result = self.run_script("--clean", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(busy.exists())
        self.assertFalse((self.derived / "AIUsageMenuBar-old").exists())

    def test_clean_without_terminal_needs_yes(self):
        result = self.run_script("--clean")
        self.assertEqual(result.returncode, 2)
        self.assertTrue((self.repo / "build").exists())

    def test_unknown_argument(self):
        self.assertEqual(self.run_script("--force").returncode, 2)


if __name__ == "__main__":
    unittest.main()
