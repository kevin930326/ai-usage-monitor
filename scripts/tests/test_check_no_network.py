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

    def test_incident_link_is_the_only_url_exception(self):
        """ADR-0015 第 2 節的唯一例外：網址只能在 UsageCore/IncidentLink.cs，而且只能是兩個事故頁前綴"""
        ok = 'class L { string[] P = ["https://status.claude.com/incidents/", "https://status.openai.com/incidents/"]; }'
        self.assertEqual(self.run_on({"UsageCore/IncidentLink.cs": ok}).returncode, 0)
        for bad in ['class L { string P = "https://evil.example/incidents/"; }',
                    'class L { string P = "https://status.claude.com/"; }',
                    'class L { string P = "http://status.claude.com/incidents/"; }']:
            with self.subTest(bad=bad):
                self.assertEqual(self.run_on({"UsageCore/IncidentLink.cs": bad}).returncode, 1)
        # 同樣的網址放在其他檔案不行
        self.assertEqual(self.run_on({"UsageCore/Other.cs": ok}).returncode, 1)
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/IncidentLink.cs": ok}).returncode, 1)

    def test_shell_open_only_in_incident_page(self):
        page = """class IncidentPage { bool Open(string u) { if (IncidentLink.Link(u) is not { } l) return false;
                  Process.Start(new ProcessStartInfo(l) { UseShellExecute = true }); return true; } }"""
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": page}).returncode, 0)
        unchecked = "class IncidentPage { void Open(string u) { Process.Start(new ProcessStartInfo(u) { UseShellExecute = true }); } }"
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": unchecked}).returncode, 1)
        elsewhere = "class Other { void M(string u) { Process.Start(new ProcessStartInfo(u) { UseShellExecute = true }); } }\n" + page
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": elsewhere}).returncode, 1)
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/A.cs": "class A { object o = new { UseShellExecute = true }; }"}).returncode, 1)
        # 只出現一次、但在 IncidentPage 前面
        before = "class Other { void M(string u) { Process.Start(new ProcessStartInfo(u) { UseShellExecute = true }); } }\n" \
                 "class IncidentPage { bool Open(string u) => IncidentLink.Link(u) != null; }"
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": before}).returncode, 1)

    def test_shell_open_cannot_hide_behind_strings_or_other_values(self):
        """Fable F-04：字串裡的類別名稱、不是常值 true 的寫法、同名但在別的專案的檔案"""
        fake = 'class Other { string s = "class IncidentPage IncidentLink.Link("; void M(string u) { ' \
               'Process.Start(new ProcessStartInfo(u) { UseShellExecute = true }); } }'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": fake}).returncode, 1)
        for value in ["!false", "flag"]:
            with self.subTest(value=value):
                body = f"class A {{ void M(string u, bool flag) {{ var i = new ProcessStartInfo(u); i.UseShellExecute = {value}; }} }}"
                self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": body}).returncode, 1)
        schtasks = 'class A { void M() { Process.Start(new ProcessStartInfo("schtasks.exe") { UseShellExecute = false }); } }'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/SystemServices.cs": schtasks}).returncode, 0)
        self.assertEqual(self.run_on({"UsageCore/SystemServices.cs": schtasks}).returncode, 1)
        self.assertEqual(self.run_on({"AumHook/SystemServices.cs": schtasks}).returncode, 1)

    def test_incident_url_must_be_exactly_a_prefix(self):
        bad = 'class L { string P = "https://status.claude.com/incidents/../evil"; }'
        self.assertEqual(self.run_on({"UsageCore/IncidentLink.cs": bad}).returncode, 1)

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
