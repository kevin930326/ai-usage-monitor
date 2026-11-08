from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

if sys.platform == "win32":
    raise unittest.SkipTest("重裝腳本是 bash（macOS）")

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "reinstall-ios.sh"
UDID = "00008000-TEST"

# 假的 xcrun：列出一台 iPhone；install、launch 都記下來並成功
XCRUN = f"""#!/bin/sh
echo "$*" >>"$HOME/xcrun.calls"
case "$*" in
  *"list devices"*)
    while [ $# -gt 0 ]; do [ "$1" = --json-output ] && out=$2; shift; done
    cat >"$out" <<'JSON'
{json.dumps({"result": {"devices": [{"hardwareProperties": {
    "platform": "iOS", "reality": "physical", "deviceType": "iPhone", "udid": UDID},
    "deviceProperties": {"name": "iPhone"}, "connectionProperties": {"transportType": "localNetwork"}}]}})}
JSON
    ;;
esac
exit 0
"""
# 假的 xcodebuild：依環境變數決定描述檔還剩幾小時，或像沒登入時一樣建置失敗
XCODEBUILD = """#!/bin/sh
[ -n "$FAKE_BUILD_LOG" ] && echo "$FAKE_BUILD_LOG"
[ -n "$FAKE_BUILD_FAIL" ] && { echo '** BUILD FAILED **'; exit 65; }
while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && derived=$2; shift; done
app="$derived/Build/Products/Release-iphoneos/AIUsageMonitor.app"
mkdir -p "$app/PlugIns/UsageWidget.appex"
cp "$HOME/app.plist" "$app/embedded.mobileprovision"
cp "$HOME/widget.plist" "$app/PlugIns/UsageWidget.appex/embedded.mobileprovision"
"""
SECURITY = '#!/bin/sh\n[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"\nexit 1\n'
OSASCRIPT = '#!/bin/sh\nshift 6\necho "$1" >>"$HOME/notifications"\n'


class ReinstallSigningTest(unittest.TestCase):
    """reinstall-ios.sh 從建置到安裝（假的 xcodebuild、devicectl、security、osascript）：
    描述檔快到期或 Xcode 沒登入時不安裝、不記成功，並立刻通知一次（審查 C-03）。"""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.home = Path(self.dir.name)
        config_dir = self.home / "Library" / "Application Support" / "AIUsageMonitor"
        config_dir.mkdir(parents=True)
        (config_dir / "config.json").write_text(json.dumps(
            {"development_team": "TEAM123456", "iphone_udid": UDID}))
        self.state = config_dir / "reinstall-state.json"
        self.log = self.home / "Library" / "Logs" / "AIUsageMonitor" / "reinstall.log"
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        for tool, body in (("xcrun", XCRUN), ("xcodebuild", XCODEBUILD), ("security", SECURITY),
                           ("osascript", OSASCRIPT), ("xcodegen", "#!/bin/sh\nexit 0\n")):
            (bin_dir / tool).write_text(body)
            (bin_dir / tool).chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home), "PATH": f"{bin_dir}:{os.environ['PATH']}"}
        self.env.pop("AUM_PYTHON", None)

    def tearDown(self):
        self.dir.cleanup()

    def profiles(self, app_hours: float, widget_hours: float) -> None:
        for name, hours in (("app.plist", app_hours), ("widget.plist", widget_hours)):
            expires = datetime.fromtimestamp(time.time() + hours * 3600, timezone.utc).replace(tzinfo=None)
            (self.home / name).write_bytes(plistlib.dumps({"ExpirationDate": expires}))

    def run_script(self, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(["/bin/bash", str(SCRIPT)], capture_output=True, text=True,
                              env={**self.env, **env}, timeout=60)

    def read(self, name: str) -> str:
        path = self.home / name
        return path.read_text() if path.exists() else ""

    def installed(self) -> bool:
        return "device install app" in self.read("xcrun.calls")

    def test_fresh_profile_installs_and_records_expiry(self):
        self.profiles(167, 167.5)
        out = self.run_script()
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertTrue(self.installed())
        state = json.loads(self.state.read_text())
        self.assertAlmostEqual(state["profile_expires"], time.time() + 167 * 3600, delta=120)

    def test_widget_profile_expiring_soon_blocks_install(self):
        # 主 App 的描述檔是新的，Widget 的只剩 23 小時：取最早的
        self.profiles(167, 23)
        out = self.run_script()
        self.assertEqual(out.returncode, 5, out.stdout + out.stderr)
        self.assertFalse(self.installed())
        self.assertFalse("last_success" in json.loads(self.state.read_text()))
        self.assertIn("Xcode 沒有更新描述檔", self.read("notifications"))

    def test_boundary_at_min_profile_hours(self):
        self.profiles(24.1, 24.1)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue(self.installed())

    def test_no_accounts_with_cached_profile_notifies_once(self):
        self.profiles(9, 9)
        log = "warning: No Accounts: Add a new account in Accounts settings."
        self.assertEqual(self.run_script(FAKE_BUILD_LOG=log).returncode, 5)
        self.assertEqual(self.run_script(FAKE_BUILD_LOG=log).returncode, 5)
        self.assertFalse(self.installed())
        notifications = self.read("notifications").splitlines()
        self.assertEqual(len(notifications), 1)
        self.assertIn("Xcode 沒有登入 Apple ID", notifications[0])

    def test_build_failing_with_no_accounts_notifies_right_away(self):
        out = self.run_script(FAKE_BUILD_FAIL="1",
                              FAKE_BUILD_LOG="error: No Accounts: Add a new account in Accounts settings.")
        self.assertEqual(out.returncode, 1)
        self.assertIn("Xcode 沒有登入 Apple ID", self.read("notifications"))


if __name__ == "__main__":
    unittest.main()
