from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "reinstall-ios.sh"
HELPER = SCRIPT.with_name("reinstall_ios_helper.py")


class ReinstallScriptTestCase(unittest.TestCase):
    """以假的 xcrun 讓 scripts/reinstall-ios.sh 在取得鎖之後的第一步（列出裝置）就失敗（結束碼 2），
    不建置、不連手機，也不讀真正的 config.json（HOME 指向臨時資料夾）。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        home = Path(self.dir.name)
        self.config_dir = home / "Library" / "Application Support" / "AIUsageMonitor"
        self.config_dir.mkdir(parents=True)
        (self.config_dir / "config.json").write_text(json.dumps(
            {"development_team": "TEAM123456", "iphone_udid": "00008000-TEST"}))
        self.lock = self.config_dir / ".reinstall.lock"
        self.log = home / "Library" / "Logs" / "AIUsageMonitor" / "reinstall.log"
        bin_dir = home / "bin"
        bin_dir.mkdir()
        for tool in ("xcrun", "osascript"):
            fake = bin_dir / tool
            fake.write_text("#!/bin/sh\nexit 1\n")
            fake.chmod(0o755)
        self.bin_dir = bin_dir
        self.env = {**os.environ, "HOME": str(home), "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def tearDown(self):
        self.dir.cleanup()

    def run_script(self) -> subprocess.CompletedProcess:
        return subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True,
                              env=self.env, timeout=60)

    def log_text(self) -> str:
        return self.log.read_text() if self.log.exists() else ""


class ReinstallLockTest(ReinstallScriptTestCase):
    """鎖：同時只跑一個，但程序被強制結束後留下的鎖不能讓之後的排程永遠跳過（C-02）。"""

    def dead_pid(self) -> int:
        proc = subprocess.Popen(["true"])
        proc.wait()
        return proc.pid

    def test_lock_left_by_killed_process_is_taken_over(self):
        # kill -9 或斷電：EXIT trap 沒執行，鎖與已結束的 PID 留在原處
        self.lock.mkdir()
        (self.lock / "pid").write_text(f"{self.dead_pid()}\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("開始重新安裝", self.log_text())
        self.assertFalse(self.lock.exists(), "結束後要釋放鎖")

    def test_legacy_lock_without_pid_is_taken_over(self):
        # 舊版腳本的鎖只有空資料夾
        self.lock.mkdir()
        old = time.time() - 3600
        os.utime(self.lock, (old, old))
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("開始重新安裝", self.log_text())

    def test_lock_held_by_running_process_is_respected(self):
        holder = subprocess.Popen(["sleep", "30"])
        try:
            self.lock.mkdir()
            (self.lock / "pid").write_text(f"{holder.pid}\n")
            result = self.run_script()
        finally:
            holder.kill()
            holder.wait()
        self.assertEqual(result.returncode, 0)
        self.assertIn("另一個重新安裝正在執行", result.stderr)
        self.assertNotIn("開始重新安裝", self.log_text())
        self.assertTrue(self.lock.exists(), "不能移除別人的鎖")

    def test_lock_older_than_max_runtime_is_taken_over(self):
        # PID 可能在重開機後被其他程序重用：超過最長執行時間的鎖不再相信
        holder = subprocess.Popen(["sleep", "30"])
        try:
            self.lock.mkdir()
            (self.lock / "pid").write_text(f"{holder.pid}\n")
            old = time.time() - 3 * 3600
            os.utime(self.lock / "pid", (old, old))
            result = self.run_script()
        finally:
            holder.kill()
            holder.wait()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("開始重新安裝", self.log_text())

    def test_releases_lock_after_failure(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.lock.exists())


class ReinstallPythonTest(ReinstallScriptTestCase):
    """C-13：launchd 以安裝時偵測到的 Python 啟動，腳本內的輔助程式也要用同一個，不能再依 PATH 找 python3。"""

    def test_script_uses_python_from_environment(self):
        marker = Path(self.dir.name) / "path-python-used"
        fake = self.bin_dir / "python3"
        fake.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 1\n")
        fake.chmod(0o755)
        self.env["AUM_PYTHON"] = sys.executable
        result = self.run_script()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(marker.exists(), "不應使用 PATH 中的 python3")

    def test_scheduled_passes_its_own_python(self):
        spec = importlib.util.spec_from_file_location("reinstall_ios_helper", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        with mock.patch.object(helper.subprocess, "call", return_value=0) as call:
            self.assertEqual(helper.cmd_scheduled(), 0)
        self.assertEqual(call.call_args.kwargs["env"]["AUM_PYTHON"], sys.executable)


if __name__ == "__main__":
    unittest.main()
