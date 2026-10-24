"""scripts/package-windows.py 與 scripts/install.ps1（Windows 一行安裝，FR-48）的測試。只寫暫存資料夾，不連網。
install.ps1 的實際安裝在 CI 的 Windows runner 上跑（.github/workflows/ci.yml「install.ps1 from the release zip」）。"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-windows.py"
INSTALLER = ROOT / "scripts" / "install.ps1"


class PackageWindowsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def package(self, out: Path, version="1.2.3"):
        return subprocess.run([sys.executable, str(SCRIPT), "--version", version, "--out", str(out)],
                              capture_output=True, text=True)

    def test_zip_has_only_what_windows_needs_and_is_reproducible(self):
        r = self.package(self.tmp / "a")
        self.assertEqual(r.returncode, 0, r.stderr)
        zip_path = self.tmp / "a" / "AIUsageMonitor-collector-1.2.3.zip"
        names = zipfile.ZipFile(zip_path).namelist()
        self.assertIn("collector/usage_collector/__main__.py", names)
        self.assertIn("collector/scripts/update-config.py", names)
        self.assertIn("collector/windows/install-task.ps1", names)
        self.assertFalse([n for n in names if "/tests/" in n or "__pycache__" in n or n.endswith(".sh")], names)
        self.assertEqual(self.package(self.tmp / "b").returncode, 0)
        self.assertEqual(zip_path.read_bytes(), (self.tmp / "b" / zip_path.name).read_bytes())

    def test_installer_gets_the_version_and_sha(self):
        self.assertEqual(self.package(self.tmp).returncode, 0)
        sha = hashlib.sha256((self.tmp / "AIUsageMonitor-collector-1.2.3.zip").read_bytes()).hexdigest()
        text = (self.tmp / "install.ps1").read_bytes().decode("ascii")
        self.assertIn("$ReleaseVersion = '1.2.3'", text)
        self.assertIn(f"$ReleaseSha256 = '{sha}'", text)
        self.assertNotIn("'__VERSION__'", text)
        self.assertIn("\r\n", text)

    def test_bad_version_is_refused(self):
        self.assertEqual(self.package(self.tmp, "1.2").returncode, 2)

    def test_installer_source_is_ascii_and_never_exits(self):
        # Windows PowerShell 5.1 以 Latin-1 解讀沒有 charset 的 irm 輸出；`exit` 會在 irm | iex 時關掉使用者的視窗
        text = INSTALLER.read_bytes()
        self.assertTrue(all(b < 128 for b in text), "install.ps1 只能有 ASCII")
        code = [line for line in text.decode().splitlines() if not line.lstrip().startswith("#")]
        self.assertFalse([line for line in code if line.strip().startswith("exit")], "用 throw，不要用 exit")
        self.assertEqual(text.decode().count("'__VERSION__'"), 1)
        self.assertEqual(text.decode().count("'__ZIP_SHA256__'"), 1)


if __name__ == "__main__":
    unittest.main()
