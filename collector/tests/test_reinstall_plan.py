from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

if sys.platform == "win32":
    raise unittest.SkipTest("iPhone 重裝排程只在 macOS")

HELPER = Path(__file__).resolve().parents[2] / "scripts" / "reinstall_ios_helper.py"
TZ = "Asia/Taipei"
DAY = 86400


def at(text: str) -> float:
    return datetime.fromisoformat(text).replace(tzinfo=ZoneInfo(TZ)).timestamp()


class ReinstallPlanTest(unittest.TestCase):
    """scripts/reinstall-ios.sh --if-due 每 20 分鐘問一次要不要重新安裝（參數與腳本相同）。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.state = Path(self.dir.name) / "reinstall-state.json"

    def tearDown(self):
        self.dir.cleanup()

    def plan(self, now: str, last_success: float | None) -> str:
        if last_success is not None:
            self.state.write_text(json.dumps({"last_success": last_success}))
        env = {**os.environ, "TZ": TZ, "AUM_NOW": str(at(now))}
        out = subprocess.run([sys.executable, str(HELPER), "plan", str(self.state),
                              "6", "6.5", "07:00,15:00,23:00", "25", "20"],
                             capture_output=True, text=True, env=env, check=True)
        return out.stdout.strip()

    def test_never_succeeded_runs_any_time(self):
        self.assertEqual(self.plan("2026-10-21T03:10", None), "overdue")

    def test_skips_before_six_days_even_in_window(self):
        self.assertEqual(self.plan("2026-10-27T14:40", at("2026-10-21T15:00")), "skip")

    def test_after_six_days_only_in_windows(self):
        # 滿 6 天是 10/27 12:00，滿 6.5 天是 10/28 00:00
        last = at("2026-10-21T12:00")
        self.assertEqual(self.plan("2026-10-27T14:34", last), "skip")
        self.assertEqual(self.plan("2026-10-27T14:35", last), "window\t15:00")
        self.assertEqual(self.plan("2026-10-27T14:54", last), "window\t15:00")
        self.assertEqual(self.plan("2026-10-27T14:55", last), "skip")
        self.assertEqual(self.plan("2026-10-27T18:00", last), "skip")  # Mac 醒來補跑也略過
        self.assertEqual(self.plan("2026-10-27T22:40", last), "window\t23:00")
        self.assertEqual(self.plan("2026-10-27T06:35", at("2026-10-21T06:00")), "window\t07:00")

    def test_overdue_runs_any_time(self):
        last = at("2026-10-21T12:00")
        self.assertEqual(self.plan("2026-10-27T23:59", last), "skip")
        self.assertEqual(self.plan("2026-10-28T00:00", last), "overdue")
        self.assertEqual(self.plan("2026-10-28T03:00", last), "overdue")

    def test_window_before_midnight_shortcut(self):
        self.state.write_text(json.dumps({"last_success": at("2026-10-21T12:00")}))
        env = {**os.environ, "TZ": TZ, "AUM_NOW": str(at("2026-10-27T23:40"))}
        out = subprocess.run([sys.executable, str(HELPER), "plan", str(self.state),
                              "6", "6.5", "00:05", "25", "20"],
                             capture_output=True, text=True, env=env, check=True)
        self.assertEqual(out.stdout.strip(), "window\t00:05")


if __name__ == "__main__":
    unittest.main()
