#!/usr/bin/env python3
"""Windows App、UsageCore 與 hook 不連網、不碰密鑰（ADR-0015 第 2 節）的靜態檢查。

- 原始碼不得出現網路（System.Net、HttpClient、Socket、WinHttp、WebSocket…）與認證（CredRead、PasswordVault…）的 API
- 啟動其他程式（Process.Start、ProcessStartInfo）只能在 SystemServices.cs（觸發收集器的 schtasks.exe）
- App、UsageCore 與 hook（AumHook，ADR-0019）不得有 PackageReference（不帶第三方程式）。唯一的例外（2026-10-29，ADR-0015
  第 1 節）：角色的繪製 MascotRender 只能參考 SkiaSharp、版本以 [x.y.z] 固定，並且有 packages.lock.json（只含 SkiaSharp 與它的
  Win32、macOS 原生檔，版本相同、有雜湊）
- 不得用 CompositionTarget.Rendering（每一格都會執行；動畫只用 DoubleAnimation，ADR-0015 第 7 節）
- 唯一的例外（2026-10-29，ADR-0015 第 2 節）：事故頁連結。網址只能出現在 UsageCore/IncidentLink.cs，而且只能是
  https://status.claude.com/incidents/、https://status.openai.com/incidents/ 兩個前綴；用預設瀏覽器打開
  （UseShellExecute 不是 false）只能在 AIUsageMonitor.Windows/SystemServices.cs 的 IncidentPage 裡出現一次，而且要經過
  IncidentLink.Link 檢查
- 這是擋誤用的靜態檢查，不追資料流：SystemServices.cs 裡用 explorer.exe 開網址、IncidentPage 裡把沒檢查過的字串交給
  ShellExecute、用字串串接組出網址，都要靠 code review 擋（ADR-0015 第 2 節）
- 傳入 Release 版的執行檔（--release <資料夾>）時，另外確認不含 Debug 專用的字串（示範資料、截圖參數）

用法：python3 windows/tools/check-no-network.py [--release <publish 資料夾>] [--root <windows 資料夾>（測試用）]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FORBIDDEN = [
    # 網路：.NET、Win32（DLL 名稱不分大小寫）、WinRT、WPF 的瀏覽器與超連結、網址
    r"System\.Net\b", r"\bHttpClient\b", r"\bWebRequest\b", r"\bWebClient\b", r"\bSocket\b", r"\bTcpClient\b", r"\bUdpClient\b",
    r"\bWebSocket", r"(?i:winhttp)", r"(?i:wininet)", r"(?i:ws2_32)", r"(?i:urlmon)", r"\bDns\b", r"URLDownloadToFile", r"\bNamedPipe",
    r"Windows\.Networking", r"Windows\.Web\b", r"\bWebBrowser\b", r"\bWebView", r"\bHyperlink\b", r"NavigateUri", r"\bUri\b",
    r"(?i:https?://)",
    # 認證與密鑰
    r"\bCredRead", r"\bCredWrite", r"\bCredEnumerate", r"\bPasswordVault\b", r"\bProtectedData\b", r"(?i:advapi32)",
    # 每一格都執行的回呼（動畫只用 DoubleAnimation）
    r"CompositionTarget\.Rendering",
]
PROCESS = re.compile(r"\bProcess\.Start\b|\bProcessStartInfo\b|\bShellExecute")
PROCESS_ALLOWED = ("AIUsageMonitor.Windows", "SystemServices.cs")
# 事故頁連結的例外：只有這個檔案可以寫網址，而且只能是這兩個前綴
URL_ALLOWED_FILE = ("UsageCore", "IncidentLink.cs")
URL_ALLOWED = ("https://status.claude.com/incidents/", "https://status.openai.com/incidents/")
URL = re.compile(r"(?i:https?://)")
# 用預設程式打開：UseShellExecute 只要不是寫明 = false 都算
SHELL_OPEN = re.compile(r"\bUseShellExecute\b(?!\s*=\s*false\b)")
# 第三方套件的唯一例外：角色的繪製（ADR-0015 第 1 節）
SKIA_PROJECT = ("MascotRender", "MascotRender.csproj")
SKIA_REFERENCE = re.compile(r'<PackageReference\s+Include="SkiaSharp"\s+Version="\[(\d+\.\d+\.\d+)\]"\s*/>')
SKIA_LOCKED = {"SkiaSharp", "SkiaSharp.NativeAssets.Win32", "SkiaSharp.NativeAssets.macOS"}
# Release 版不該有的字串（DebugTools.cs 的參數與示範資料）；.NET 的字串以 UTF-16LE 存放
DEBUG_STRINGS = ["--render", "--demo", "aum-demo-", "DebugTools", "DemoJson"]


# 字串（raw、verbatim、一般、字元）先配對、原樣保留，才不會把字串裡的 // 當成註解剝掉
_TOKENS = re.compile(r'("""[\s\S]*?"""|@"(?:[^"]|"")*"|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')|//[^\n]*|/\*[\s\S]*?\*/')


def strip_comments(text: str) -> str:
    return _TOKENS.sub(lambda m: m.group(1) or "", text)


def strip_strings(text: str) -> str:
    """連字串一起拿掉，只留程式碼（找類別名稱與呼叫時，不被字串內容騙）"""
    return _TOKENS.sub(lambda m: '""' if m.group(1) else "", text)


def check_sources(root: Path = ROOT) -> list[str]:
    problems = []
    for folder in (root / "src" / "AIUsageMonitor.Windows", root / "src" / "UsageCore", root / "src" / "AumHook",
                   root / "src" / "MascotRender"):
        for path in sorted(folder.rglob("*")):
            if path.suffix not in (".cs", ".xaml", ".csproj", ".props") or "obj" in path.parts or "bin" in path.parts:
                continue
            raw = path.read_text(encoding="utf-8")
            code = strip_comments(raw) if path.suffix == ".cs" else raw
            if path.suffix == ".xaml":
                # XML 命名空間是識別字、不會連線
                code = re.sub(r'xmlns(?::\w+)?="[^"]*"', "", code)
            rel = path.relative_to(root.parent)
            url_ok = path.parts[-2:] == URL_ALLOWED_FILE
            for pattern in FORBIDDEN:
                for m in re.finditer(pattern, code):
                    # 網址要剛好是前綴、字串在這裡結束（不能在後面接路徑）
                    if url_ok and pattern == r"(?i:https?://)" and code.startswith(tuple(u + '"' for u in URL_ALLOWED), m.start()):
                        continue
                    problems.append(f"{rel}: 不允許 {m.group(0)}")
            system_services = path.parts[-2:] == PROCESS_ALLOWED
            if path.suffix == ".cs":
                bare = strip_strings(raw)
                opens = list(SHELL_OPEN.finditer(bare))
                if opens and not system_services:
                    problems.append(f"{rel}: 只有 SystemServices.cs 的 IncidentPage 可以用預設程式打開（UseShellExecute）")
                elif len(opens) > 1:
                    problems.append(f"{rel}: UseShellExecute 只能出現一次（IncidentPage）")
                elif opens:
                    start = bare.find("class IncidentPage")
                    if start < 0 or opens[0].start() < start or "IncidentLink.Link(" not in bare[start:]:
                        problems.append(f"{rel}: UseShellExecute 只能在 IncidentPage 裡、經過 IncidentLink.Link 檢查")
            if path.suffix == ".cs" and not system_services and PROCESS.search(code):
                problems.append(f"{rel}: 只有 SystemServices.cs 可以啟動其他程式")
            if path.suffix == ".csproj" and path.parts[-2:] == SKIA_PROJECT:
                problems += check_skia(path, code, rel)
            elif path.suffix == ".csproj" and "PackageReference" in code:
                problems.append(f"{rel}: 不允許 PackageReference（App 與 UsageCore 不帶第三方套件）")
    return problems


def check_skia(path: Path, code: str, rel: Path) -> list[str]:
    """MascotRender 只能參考固定版本的 SkiaSharp，而且用 packages.lock.json 鎖住雜湊"""
    references = re.findall(r"<PackageReference\b[^>]*>", code)
    pinned = SKIA_REFERENCE.findall(code)
    if len(references) != 1 or len(pinned) != 1:
        return [f"{rel}: 只允許一個 PackageReference：SkiaSharp，版本以 [x.y.z] 固定"]
    version = pinned[0]
    if not re.search(r"<RestorePackagesWithLockFile>\s*true\s*</RestorePackagesWithLockFile>", code):
        return [f"{rel}: 要用 packages.lock.json（RestorePackagesWithLockFile）"]
    lock_path = path.with_name("packages.lock.json")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return [f"{rel}: 找不到或讀不懂 packages.lock.json"]
    problems = []
    for framework, packages in lock.get("dependencies", {}).items():
        for name, entry in packages.items():
            if entry.get("type") == "Project":
                continue
            if name not in SKIA_LOCKED:
                problems.append(f"{rel}: packages.lock.json 有不允許的套件 {name}（{framework}）")
            elif entry.get("resolved") != version or not entry.get("contentHash"):
                problems.append(f"{rel}: packages.lock.json 的 {name} 不是 {version} 或沒有雜湊")
    return problems


def check_release(folder: Path) -> list[str]:
    problems = []
    binaries = [p for p in folder.rglob("*") if p.suffix in (".dll", ".exe") and p.name.startswith(("AIUsageMonitor", "aum-hook"))]
    if not binaries:
        return [f"{folder}: 找不到 AIUsageMonitor 的執行檔"]
    for path in binaries:
        data = path.read_bytes()
        for s in DEBUG_STRINGS:
            if s.encode("utf-16-le") in data or s.encode("utf-8") in data:
                problems.append(f"{path.name}: Release 版含有 Debug 專用的字串 {s!r}")
    return problems


def main(argv: list[str]) -> int:
    root = Path(argv[argv.index("--root") + 1]) if "--root" in argv else ROOT
    problems = check_sources(root)
    if "--release" in argv:
        problems += check_release(Path(argv[argv.index("--release") + 1]))
    for p in problems:
        print(p)
    print(f"check-no-network: {'OK' if not problems else f'{len(problems)} 個問題'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
