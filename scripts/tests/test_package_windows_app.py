"""scripts/package-windows-app.py（Windows App 的自含式 zip，ADR-0015 第 8 節）的測試。
不執行 dotnet publish（慢、第一次要下載執行環境）：實際的建置在 release.yml 的 Windows job（PR 改到發布相關檔案時也會跑）。
這裡測版本格式、發布前的檢查（缺檔、.pdb、測試組件、Debug 字串、組件版本）與 zip 的內容。只寫暫存資料夾。"""
import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-windows-app.py"
spec = importlib.util.spec_from_file_location("package_windows_app", SCRIPT)
pkg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pkg)


def informational(version: str) -> bytes:
    """組件 metadata 裡 AssemblyInformationalVersion 的樣子：prolog 0x01 0x00、長度、UTF-8"""
    value = version.encode()
    return b"\x01\x00" + bytes([len(value)]) + value + b"\x00\x00"


class PackageWindowsAppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def release_folder(self, version="1.2.3", extra=()):
        folder = self.tmp / "win-x64"
        folder.mkdir()
        for name in ("AIUsageMonitor.exe", "AIUsageMonitor.Core.dll", "coreclr.dll", "PresentationFramework.dll"):
            (folder / name).write_bytes(b"MZ release")
        (folder / "AIUsageMonitor.dll").write_bytes(b"MZ" + informational(f"{version}+abc123def"))
        for name, data in extra:
            (folder / name).parent.mkdir(parents=True, exist_ok=True)
            (folder / name).write_bytes(data)
        return folder

    def test_bad_version_is_rejected_before_building(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "--version", "1.2", "--out", str(self.tmp)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("版本格式不對", r.stderr)
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_clean_release_folder_passes(self):
        self.assertEqual(pkg.verify(self.release_folder("1.2.3-rc.1"), "1.2.3-rc.1"), [])

    def test_wrong_assembly_version_fails(self):
        problems = pkg.verify(self.release_folder("1.2.2"), "1.2.3")
        self.assertTrue(any("組件版本" in p for p in problems), problems)

    def test_debug_symbols_tests_and_debug_strings_fail(self):
        folder = self.release_folder(extra=[
            ("AIUsageMonitor.pdb", b""), ("UsageCore.Tests.dll", b""), ("xunit.core.dll", b""),
            ("AIUsageMonitor.Debug.dll", "--demo".encode("utf-16-le")),
        ])
        problems = "\n".join(pkg.verify(folder, "1.2.3"))
        for name in ("AIUsageMonitor.pdb", "UsageCore.Tests.dll", "xunit.core.dll", "--demo"):
            self.assertIn(name, problems)

    def test_missing_runtime_fails(self):
        folder = self.release_folder()
        (folder / "coreclr.dll").unlink()
        self.assertTrue(any("coreclr.dll" in p for p in pkg.verify(folder, "1.2.3")))

    def test_zip_has_one_folder_sorted_with_fixed_times(self):
        folder = self.release_folder(extra=[("zh-Hant/AIUsageMonitor.resources.dll", b"r")])
        dest = self.tmp / "a.zip"
        pkg.build_zip(folder, dest)
        infos = zipfile.ZipFile(dest).infolist()
        names = [i.filename for i in infos]
        self.assertEqual(names, sorted(names))
        self.assertTrue(all(n.startswith("AIUsageMonitor/") for n in names))
        self.assertIn("AIUsageMonitor/zh-Hant/AIUsageMonitor.resources.dll", names)
        self.assertEqual({i.date_time for i in infos}, {pkg.FIXED_TIME})
        pkg.build_zip(folder, self.tmp / "b.zip")
        self.assertEqual(dest.read_bytes(), (self.tmp / "b.zip").read_bytes())


if __name__ == "__main__":
    unittest.main()
