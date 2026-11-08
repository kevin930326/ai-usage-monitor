from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
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

    def plan(self, now: str, last_success: float | None, profile_expires: float | None = None) -> str:
        if last_success is not None:
            state = {"last_success": last_success}
            if profile_expires is not None:
                state["profile_expires"] = profile_expires
            self.state.write_text(json.dumps(state))
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

    def test_counts_from_profile_creation_when_older(self):
        # 11/06 15:30 裝成功，但 Xcode 沿用 10/31 00:49 建立的描述檔（11/07 00:49 到期）：
        # 從描述檔建立時算，11/06 06:49 已滿 6 天、12:49 滿 6.5 天
        last, expires = at("2026-11-06T15:30"), at("2026-11-07T00:49")
        self.assertEqual(self.plan("2026-11-06T16:00", last, expires), "overdue")
        self.assertEqual(self.plan("2026-11-06T16:00", last), "skip")

    def test_newer_profile_does_not_delay(self):
        # 描述檔比上次成功還新（手動用 Xcode 裝過）時仍從上次成功算
        last = at("2026-10-21T12:00")
        self.assertEqual(self.plan("2026-10-28T00:00", last, at("2026-10-30T00:00")), "overdue")


class ReinstallStateTest(unittest.TestCase):
    """描述檔到期時間與立刻通知（Xcode 沒有登入 Apple ID 時沿用快到期的描述檔）。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.state = self.root / "reinstall-state.json"

    def tearDown(self):
        self.dir.cleanup()

    def run_helper(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True, text=True,
                              env={**os.environ, "AUM_NOW": str(at("2026-11-06T15:30")), **(env or {})})

    def test_success_records_profile_expiry(self):
        self.run_helper("success", str(self.state), "1793990000")
        self.assertEqual(json.loads(self.state.read_text()),
                         {"last_success": at("2026-11-06T15:30"), "profile_expires": 1793990000.0})
        self.run_helper("success", str(self.state))
        self.assertEqual(json.loads(self.state.read_text()), {"last_success": at("2026-11-06T15:30")})

    def test_failure_zero_hours_notifies_once(self):
        self.assertEqual(self.run_helper("failure", str(self.state), "0").stdout, "notify\t0\n")
        self.assertEqual(self.run_helper("failure", str(self.state), "0").stdout, "")

    def test_signing_notifies_after_general_failure_was_notified(self):
        # 手機連不上已通知過，之後 Xcode 被登出：登入提醒仍要立刻發一次，之後不重複，成功後重設
        self.state.write_text(json.dumps({"failing_since": at("2026-11-05T12:00"), "failure_notified": True}))
        self.assertEqual(self.run_helper("failure", str(self.state), "24").stdout, "")
        self.assertTrue(self.run_helper("failure", str(self.state), "0", "signing").stdout.startswith("notify\t"))
        self.assertEqual(self.run_helper("failure", str(self.state), "0", "signing").stdout, "")
        self.run_helper("success", str(self.state), "1793990000")
        self.assertEqual(self.run_helper("failure", str(self.state), "0", "signing").stdout, "notify\t0\n")

    def test_expiry_is_earliest_embedded_profile(self):
        # 描述檔是 CMS 簽章的 plist；以假的 security 指令直接印出檔案內容
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "security"
        fake.write_text('#!/bin/sh\n[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"\nexit 1\n')
        fake.chmod(0o755)
        app = self.root / "AIUsageMonitor.app"
        widget = app / "PlugIns" / "UsageWidget.appex"
        widget.mkdir(parents=True)
        for folder, expires in ((app, "2026-11-13T15:30"), (widget, "2026-11-07T00:49")):
            # plist 的日期是 UTC，plistlib 寫入時不看 tzinfo，要先換成不帶時區的 UTC
            date = datetime.fromisoformat(expires).replace(tzinfo=ZoneInfo(TZ)).astimezone(timezone.utc)
            date = date.replace(tzinfo=None)
            (folder / "embedded.mobileprovision").write_bytes(plistlib.dumps({"ExpirationDate": date}))
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}
        out = self.run_helper("expiry", str(app), env=env)
        self.assertEqual(out.stdout.strip(), f"{at('2026-11-07T00:49'):.0f}")
        (widget / "embedded.mobileprovision").unlink()
        (widget / "embedded.mobileprovision").write_text("not a plist")
        self.assertEqual(self.run_helper("expiry", str(app), env=env).returncode, 1)

    def test_stale_profiles_lists_only_ours_expiring_soon(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "security"
        fake.write_text('#!/bin/sh\n[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"\nexit 1\n')
        fake.chmod(0o755)
        cache = self.root / "profiles"
        cache.mkdir()

        def write(file: str, name: str, expires: str) -> None:
            date = datetime.fromisoformat(expires).replace(tzinfo=ZoneInfo(TZ)).astimezone(timezone.utc)
            (cache / file).write_bytes(plistlib.dumps({"Name": name, "ExpirationDate": date.replace(tzinfo=None)}))

        prefix = "iOS Team Provisioning Profile: "
        write("a.mobileprovision", prefix + "io.github.kevin930326.AIUsageMonitor", "2026-11-07T00:49")
        write("b.mobileprovision", prefix + "io.github.kevin930326.AIUsageMonitor.UsageWidget", "2026-11-07T00:49")
        write("c.mobileprovision", prefix + "io.github.kevin930326.AIUsageMonitor", "2026-11-13T15:00")
        write("d.mobileprovision", prefix + "com.example.Other", "2026-11-07T00:49")
        (cache / "e.mobileprovision").write_text("not a plist")
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "AUM_PROFILE_DIRS": f"{cache}:{self.root / 'missing'}"}
        out = self.run_helper("stale-profiles", "io.github.kevin930326.AIUsageMonitor", "144", env=env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.splitlines(), [str(cache / "a.mobileprovision"), str(cache / "b.mobileprovision")])


if __name__ == "__main__":
    unittest.main()
