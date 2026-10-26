"""windows/tools/check-no-network.py：Windows App 不連網、不碰密鑰的靜態檢查（ADR-0015 第 2 節，F-12）。"""
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "windows" / "tools" / "check-no-network.py"


class CheckNoNetworkTests(unittest.TestCase):
    def run_on(self, files: dict[str, str]) -> subprocess.CompletedProcess:
        tmp = Path(tempfile.mkdtemp(prefix="aum-no-network-")) / "windows"
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(tmp.parent)]))
        for rel, body in files.items():
            path = tmp / "src" / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(body), encoding="utf-8")
        (tmp / "src" / "UsageCore").mkdir(parents=True, exist_ok=True)
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(tmp)], capture_output=True, text=True)

    def test_repository_passes(self):
        r = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_clean_source_passes(self):
        r = self.run_on({"AIUsageMonitor.Windows/A.cs": """
            // 註解裡提到 HttpClient 沒關係
            class A { string Path => "C:\\\\data"; }
        """})
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_network_apis_fail(self):
        for code in ['var c = new HttpClient();', '[DllImport("WININET.dll")] static extern void X();',
                     '[DllImport("ws2_32.dll")] static extern void X();', 'var u = new Uri(path);',
                     'var h = new Hyperlink();', 'using Windows.Networking.Sockets;', 'Process.Start("https://example.com");']:
            with self.subTest(code=code):
                r = self.run_on({"AIUsageMonitor.Windows/A.cs": f"class A {{ void M() {{ {code} }} }}"})
                self.assertEqual(r.returncode, 1, r.stdout)

    def test_comment_marker_inside_a_string_does_not_hide_code(self):
        # 舊版把字串裡的 // 之後整行當註解剝掉
        r = self.run_on({"AIUsageMonitor.Windows/A.cs": 'class A { string s = "a//b"; object c = new System.Net.WebClient(); }'})
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("System.Net", r.stdout)

    def test_process_start_only_in_system_services(self):
        body = 'class A { void M() { System.Diagnostics.Process.Start(new ProcessStartInfo("schtasks.exe")); } }'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/A.cs": body}).returncode, 1)
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": body}).returncode, 0)

    def test_credentials_and_package_references_fail(self):
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/A.cs": "class A { void M() { CredReadW(); } }"}).returncode, 1)
        csproj = '<Project><ItemGroup><PackageReference Include="X" Version="1" /></ItemGroup></Project>'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/A.csproj": csproj}).returncode, 1)

    def test_xaml_namespaces_are_allowed(self):
        xaml = '<Application xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/App.xaml": xaml}).returncode, 0)
        link = '<TextBlock><Hyperlink NavigateUri="https://example.com" /></TextBlock>'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/B.xaml": link}).returncode, 1)


if __name__ == "__main__":
    unittest.main()
