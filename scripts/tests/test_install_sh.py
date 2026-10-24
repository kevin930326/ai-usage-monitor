"""scripts/install.sh（一行安裝，FR-53）的測試。

HOME、安裝位置、垃圾桶、LaunchAgents 與資料夾都指到暫存資料夾，以 AUM_ZIP 用本機做的假 App，
不連網、不結束或打開任何 App、不碰真的 /Applications 與 launchd。
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "install.sh"
BUNDLE_ID = "io.github.kevin930326.AIUsageMenuBar"
INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{bundle_id}</string>
<key>CFBundleExecutable</key><string>AIUsageMenuBar</string>
<key>CFBundleShortVersionString</key><string>{version}</string>
</dict></plist>
"""


@unittest.skipUnless(sys.platform == "darwin", "install.sh 用到 ditto、codesign、PlistBuddy（macOS）")
class InstallShTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = self.tmp / "home"
        self.apps = self.tmp / "Applications"
        self.trash = self.tmp / "trash"
        self.agents = self.tmp / "LaunchAgents"
        self.data = self.tmp / "data"
        for d in (self.home, self.apps, self.agents, self.data):
            d.mkdir()
        self.marker = self.tmp / "unregistered"

    def make_zip(self, version="1.2.3", bundle_id=BUNDLE_ID, sign=True, unregister_rc=0) -> tuple[Path, str]:
        build = Path(tempfile.mkdtemp(dir=self.tmp))
        app = build / "AIUsageMenuBar.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Info.plist").write_text(INFO_PLIST.format(bundle_id=bundle_id, version=version))
        exe = app / "MacOS" / "AIUsageMenuBar"
        # 假的 App：解除安裝時以 --unregister-collector 執行，留下記號
        exe.write_text(textwrap.dedent(f"""\
            #!/bin/sh
            [ "$1" = --unregister-collector ] && echo {version} > "{self.marker}"
            exit {unregister_rc}
        """))
        exe.chmod(0o755)
        if sign:
            subprocess.run(["codesign", "--force", "--deep", "-s", "-", str(app.parent)], check=True, capture_output=True)
        zip_path = self.tmp / f"app-{version}-{bundle_id}-{sign}-{unregister_rc}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app.parent), str(zip_path)], check=True)
        return zip_path, hashlib.sha256(zip_path.read_bytes()).hexdigest()

    def run_script(self, *args, zip_path=None, extra_env=None) -> subprocess.CompletedProcess:
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.home), "LANG": "en_US.UTF-8",
               "AUM_INSTALL_DIR": str(self.apps), "AUM_TRASH_DIR": str(self.trash),
               "AUM_LAUNCH_AGENTS_DIR": str(self.agents), "AI_USAGE_MONITOR_HOME": str(self.data)}
        if zip_path:
            env["AUM_ZIP"] = str(zip_path)
        env.update(extra_env or {})
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, start_new_session=True, timeout=60)

    def installed_version(self) -> str:
        return subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString",
                               str(self.apps / "AIUsageMenuBar.app" / "Contents" / "Info.plist")],
                              capture_output=True, text=True, check=True).stdout.strip()

    def test_install_then_update_moves_old_version_to_trash(self):
        zip1, sha1 = self.make_zip("1.0.0")
        result = self.run_script("--version", "1.0.0", "--sha256", sha1, zip_path=zip1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SHA-256 相符", result.stdout)
        self.assertEqual(self.installed_version(), "1.0.0")
        self.assertFalse(self.trash.exists())

        zip2, sha2 = self.make_zip("1.1.0")
        result = self.run_script("--version", "v1.1.0", "--sha256", sha2, zip_path=zip2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed_version(), "1.1.0")
        self.assertEqual(len(list(self.trash.iterdir())), 1)
        # 暫存的安裝資料夾沒有留下來
        self.assertEqual(sorted(p.name for p in self.apps.iterdir()), ["AIUsageMenuBar.app"])

    def test_sha_mismatch_installs_nothing(self):
        zip_path, _ = self.make_zip()
        result = self.run_script("--version", "1.2.3", "--sha256", "0" * 64, zip_path=zip_path)
        self.assertEqual(result.returncode, 4)
        self.assertIn("SHA-256 不符", result.stderr)
        self.assertEqual(list(self.apps.iterdir()), [])

    def test_wrong_bundle_id_or_unsigned_app_is_refused(self):
        for kwargs, message in [({"bundle_id": "com.example.Other"}, "不是 AI 用量"), ({"sign": False}, "簽章")]:
            with self.subTest(**kwargs):
                zip_path, sha = self.make_zip(**kwargs)
                result = self.run_script("--version", "1.2.3", "--sha256", sha, zip_path=zip_path)
                self.assertEqual(result.returncode, 4)
                self.assertIn(message, result.stderr)
                self.assertEqual(list(self.apps.iterdir()), [])

    def test_repo_copy_without_version_refuses(self):
        zip_path, sha = self.make_zip()
        self.assertEqual(self.run_script(zip_path=zip_path).returncode, 2)
        self.assertEqual(self.run_script("--version", "1.2.3", zip_path=zip_path).returncode, 2)

    def test_legacy_collector_is_mentioned_not_touched(self):
        plist = self.agents / "io.github.kevin930326.ai-usage-monitor.plist"
        plist.write_text("<plist/>")
        zip_path, sha = self.make_zip()
        result = self.run_script("--version", "1.2.3", "--sha256", sha, zip_path=zip_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("不會另外註冊收集器", result.stdout)
        self.assertTrue(plist.exists())

    def test_uninstall_unregisters_and_keeps_data(self):
        zip_path, sha = self.make_zip("2.0.0")
        self.run_script("--version", "2.0.0", "--sha256", sha, zip_path=zip_path)
        (self.data / "usage.json").write_text("{}")
        result = self.run_script("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text().strip(), "2.0.0")  # 以 --unregister-collector 執行過
        self.assertFalse((self.apps / "AIUsageMenuBar.app").exists())
        self.assertTrue((self.data / "usage.json").exists())
        # 再跑一次不出錯
        self.assertEqual(self.run_script("--uninstall").returncode, 0)

    def test_failed_unregister_keeps_app_and_data(self):
        zip_path, sha = self.make_zip("2.0.0", unregister_rc=1)
        self.run_script("--version", "2.0.0", "--sha256", sha, zip_path=zip_path)
        (self.data / "usage.json").write_text("{}")
        result = self.run_script("--uninstall", "--purge", "--yes")
        self.assertEqual(result.returncode, 5)
        self.assertIn("無法停用內建收集器", result.stderr)
        self.assertTrue((self.apps / "AIUsageMenuBar.app").exists())
        self.assertTrue((self.data / "usage.json").exists())
        self.assertFalse(self.trash.exists())

    def test_purge_moves_data_and_logs_to_trash(self):
        logs = self.home / "Library" / "Logs" / "AIUsageMonitor"
        logs.mkdir(parents=True)
        (self.data / "usage.json").write_text("{}")
        # 沒有終端機可以詢問、也沒有 --yes：不移走
        result = self.run_script("--uninstall", "--purge")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.data.exists())
        result = self.run_script("--uninstall", "--purge", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.data.exists())
        self.assertFalse(logs.exists())
        self.assertEqual(len(list(self.trash.iterdir())), 2)

    def test_purge_refuses_while_legacy_collector_uses_the_data(self):
        (self.agents / "io.github.kevin930326.ai-usage-monitor.plist").write_text("<plist/>")
        result = self.run_script("--uninstall", "--purge", "--yes")
        self.assertEqual(result.returncode, 0)
        self.assertIn("uninstall-launchd.sh", result.stdout)
        self.assertTrue(self.data.exists())

    def test_release_placeholders_appear_once(self):
        # build-release.sh 只換這兩行；格式改了要一起改 build-release.sh
        text = SCRIPT.read_text()
        self.assertEqual(text.count('VERSION="__VERSION__"'), 1)
        self.assertEqual(text.count('ZIP_SHA256="__ZIP_SHA256__"'), 1)
        self.assertNotIn("sudo ", text.replace("（不要用 sudo）", "").replace("不使用 sudo", ""))


if __name__ == "__main__":
    unittest.main()
