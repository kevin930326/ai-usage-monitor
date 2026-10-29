"""windows/tools/check-no-network.py：Windows App 不連網、不碰密鑰的靜態檢查（ADR-0015 第 2 節，F-12）。"""
import json
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

    def test_skia_is_the_only_package_exception(self):
        csproj = ('<Project><PropertyGroup><RestorePackagesWithLockFile>true</RestorePackagesWithLockFile></PropertyGroup>'
                  '<ItemGroup><PackageReference Include="SkiaSharp" Version="[4.153.1]" /></ItemGroup></Project>')
        def lock(*names, version="4.153.1", hashed=True):
            deps = {n: {"type": "Transitive", "resolved": version, "contentHash": "x" if hashed else ""} for n in names}
            if "SkiaSharp" in deps:
                deps["SkiaSharp"].update(type="Direct", requested=f"[{version}, {version}]")
            deps["AIUsageMonitor.Core"] = {"type": "Project"}
            return json.dumps({"version": 1, "dependencies": {"net10.0": deps}})
        good = lock("SkiaSharp", "SkiaSharp.NativeAssets.Win32", "SkiaSharp.NativeAssets.macOS")
        ok = {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": good}
        self.assertEqual(self.run_on(ok).returncode, 0, self.run_on(ok).stdout)
        # 同一個 csproj 放在 App 裡仍然不行
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/A.csproj": csproj}).returncode, 1)
        # 版本沒有固定、多一個套件、沒有鎖定檔、鎖定檔多了套件或版本不同、沒有雜湊
        cases = [
            {"MascotRender/MascotRender.csproj": csproj.replace("[4.153.1]", "4.153.1"), "MascotRender/packages.lock.json": good},
            {"MascotRender/MascotRender.csproj": csproj.replace("</ItemGroup>", '<PackageReference Include="X" Version="[1.0.0]" /></ItemGroup>'),
             "MascotRender/packages.lock.json": good},
            {"MascotRender/MascotRender.csproj": csproj},
            {"MascotRender/MascotRender.csproj": csproj.replace("true</Restore", "false</Restore"), "MascotRender/packages.lock.json": good},
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": lock("SkiaSharp", "Evil.Package")},
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": lock("SkiaSharp", version="4.154.0")},
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": lock("SkiaSharp", hashed=False)},
            # 空的鎖定檔、少了原生檔、SkiaSharp 不是直接參考（Fable F-07）
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": json.dumps({"version": 1, "dependencies": {"net10.0": {}}})},
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": json.dumps({"version": 1})},
            {"MascotRender/MascotRender.csproj": csproj, "MascotRender/packages.lock.json": lock("SkiaSharp")},
            {"MascotRender/MascotRender.csproj": csproj,
             "MascotRender/packages.lock.json": good.replace('"Direct"', '"Transitive"')},
        ]
        for files in cases:
            self.assertEqual(self.run_on(files).returncode, 1, files)
        # 繪製的程式碼也不能連網
        self.assertEqual(self.run_on({**ok, "MascotRender/A.cs": "class A { HttpClient c; }"}).returncode, 1)

    def test_packages_cannot_come_in_through_shared_files_or_other_projects(self):
        # Fable F-01：共用設定、別的資料夾的新專案、中央套件管理、nuget.config 都不能帶套件進來
        reference = '<Project><ItemGroup><PackageReference Include="Evil" Version="1.0.0" /></ItemGroup></Project>'
        cases = [
            {"../Directory.Build.props": reference},
            {"AIUsageMonitor.Windows/Directory.Build.props": reference},
            {"Other/Other.csproj": reference},
            {"../Directory.Build.targets": reference.replace("PackageReference", "PackageDownload")},
            {"Directory.Packages.props": '<Project><ItemGroup><PackageVersion Include="Evil" Version="1" /></ItemGroup></Project>'},
            {"../Directory.Build.props": '<Project><ItemGroup><GlobalPackageReference Include="Evil" /></ItemGroup></Project>'},
            {"../nuget.config": "<configuration />"},
        ]
        for files in cases:
            self.assertEqual(self.run_on(files).returncode, 1, files)
        # 測試專案可以參考測試套件
        self.assertEqual(self.run_on({"../tests/T/T.csproj": reference}).returncode, 0)

    def test_release_has_no_native_pdb(self):
        tmp = Path(tempfile.mkdtemp(prefix="aum-release-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(tmp)]))
        (tmp / "AIUsageMonitor.exe").write_bytes(b"ok")
        (tmp / "AIUsageMonitor.pdb").write_bytes(b"ok")
        args = [sys.executable, str(SCRIPT), "--release", str(tmp)]
        self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
        (tmp / "libSkiaSharp.pdb").write_bytes(b"x")
        self.assertEqual(subprocess.run(args, capture_output=True).returncode, 1)

    def test_xaml_namespaces_are_allowed(self):
        xaml = '<Application xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" />'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/App.xaml": xaml}).returncode, 0)
        link = '<TextBlock><Hyperlink NavigateUri="https://example.com" /></TextBlock>'
        self.assertEqual(self.run_on({"AIUsageMonitor.Windows/B.xaml": link}).returncode, 1)


if __name__ == "__main__":
    unittest.main()
