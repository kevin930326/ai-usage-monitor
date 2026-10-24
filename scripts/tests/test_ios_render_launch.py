"""scripts/ios-render-launch.sh：剛開機後第一次啟動不出畫面時，重新啟動一次。

假的 xcrun 放在 PATH 最前面，依 FAKE_SCENARIO 模擬 App 每次啟動的行為；等待時間以
IOS_RENDER_FIRST_WAIT／IOS_RENDER_WAIT 縮短成幾秒，不需要模擬器。
"""
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts" / "ios-render-launch.sh"

# 每次 `simctl launch` 記一行（啟動參數與收到的 SIMCTL_CHILD_AUM_RENDER），依情境寫出 PNG 與 island-sizes.json
FAKE_XCRUN = r"""#!/bin/bash
[ "$1 $2" = "simctl launch" ] || exit 0
echo "$* render=${SIMCTL_CHILD_AUM_RENDER:-}" >>"$FAKE_LOG"
n=$(wc -l <"$FAKE_LOG" | tr -d ' ')
case "$FAKE_SCENARIO" in
  ok) touch "$FAKE_DOCS/island-normal.png" "$FAKE_DOCS/island-sizes.json" ;;
  stall-then-ok) [ "$n" = 1 ] || touch "$FAKE_DOCS/island-normal.png" "$FAKE_DOCS/island-sizes.json" ;;
  slow) [ "$n" = 1 ] && { touch "$FAKE_DOCS/island-normal.png"; (sleep 3; touch "$FAKE_DOCS/island-sizes.json") & } ;;
  never) ;;
esac
exit 0
"""


class LaunchIosRenderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="aum-ios-render-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)]))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        xcrun = bin_dir / "xcrun"
        xcrun.write_text(FAKE_XCRUN)
        xcrun.chmod(0o755)
        self.docs = self.tmp / "Documents"
        self.docs.mkdir()
        self.log = self.tmp / "launches.log"
        self.log.touch()
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_LOG": str(self.log),
                    "FAKE_DOCS": str(self.docs), "IOS_RENDER_FIRST_WAIT": "1", "IOS_RENDER_WAIT": "6",
                    "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}

    def launch(self, scenario):
        script = textwrap.dedent(f"""
            set -euo pipefail
            source "{LIB}"
            rc=0
            SIMCTL_CHILD_AUM_RENDER=1 launch_ios_render UDID io.example.app "$FAKE_DOCS" -AppleLocale zh_TW || rc=$?
            echo "rc=$rc"
        """)
        r = subprocess.run(["/bin/bash", "-c", script], capture_output=True, text=True, timeout=60,
                           env={**self.env, "FAKE_SCENARIO": scenario})
        launches = self.log.read_text().splitlines()
        return r, launches

    def test_first_launch_succeeds_without_relaunch(self):
        r, launches = self.launch("ok")
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertEqual(len(launches), 1)
        self.assertNotIn("重新啟動", r.stdout)
        # 啟動參數與呼叫端設定的 SIMCTL_CHILD_* 都傳到 simctl launch
        self.assertEqual(launches[0], "simctl launch --terminate-running-process UDID io.example.app -AppleLocale zh_TW render=1")

    def test_no_png_after_first_wait_relaunches_once(self):
        r, launches = self.launch("stall-then-ok")
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertEqual(len(launches), 2)
        self.assertIn("第一次啟動沒有完成", r.stdout)
        self.assertTrue(launches[1].endswith("render=1"))

    def test_rendering_in_progress_is_not_restarted(self):
        r, launches = self.launch("slow")
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertEqual(len(launches), 1, "已經有 PNG 時不該在第一段等待後重新啟動")

    def test_two_failed_launches_return_1(self):
        r, launches = self.launch("never")
        self.assertIn("rc=1", r.stdout, r.stderr)
        self.assertEqual(len(launches), 2)


if __name__ == "__main__":
    unittest.main()
