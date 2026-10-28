#!/usr/bin/env python3
"""Windows App、UsageCore 與 hook 不連網、不碰密鑰（ADR-0015 第 2 節）的靜態檢查。

- 原始碼不得出現網路（System.Net、HttpClient、Socket、WinHttp、WebSocket…）與認證（CredRead、PasswordVault…）的 API
- 啟動其他程式（Process.Start、ProcessStartInfo）只能在 SystemServices.cs（觸發收集器的 schtasks.exe）
- App、UsageCore 與 hook（AumHook，ADR-0019）不得有 PackageReference（不帶第三方程式）
- 不得用 CompositionTarget.Rendering（每一格都會執行；動畫只用 DoubleAnimation，ADR-0015 第 7 節）
- 傳入 Release 版的執行檔（--release <資料夾>）時，另外確認不含 Debug 專用的字串（示範資料、截圖參數）

用法：python3 windows/tools/check-no-network.py [--release <publish 資料夾>] [--root <windows 資料夾>（測試用）]
"""
from __future__ import annotations

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
PROCESS_ALLOWED = {"SystemServices.cs"}
# Release 版不該有的字串（DebugTools.cs 的參數與示範資料）；.NET 的字串以 UTF-16LE 存放
DEBUG_STRINGS = ["--render", "--demo", "aum-demo-", "DebugTools", "DemoJson"]


# 字串（raw、verbatim、一般、字元）先配對、原樣保留，才不會把字串裡的 // 當成註解剝掉
_TOKENS = re.compile(r'("""[\s\S]*?"""|@"(?:[^"]|"")*"|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\')|//[^\n]*|/\*[\s\S]*?\*/')


def strip_comments(text: str) -> str:
    return _TOKENS.sub(lambda m: m.group(1) or "", text)


def check_sources(root: Path = ROOT) -> list[str]:
    problems = []
    for folder in (root / "src" / "AIUsageMonitor.Windows", root / "src" / "UsageCore", root / "src" / "AumHook"):
        for path in sorted(folder.rglob("*")):
            if path.suffix not in (".cs", ".xaml", ".csproj", ".props") or "obj" in path.parts or "bin" in path.parts:
                continue
            raw = path.read_text(encoding="utf-8")
            code = strip_comments(raw) if path.suffix == ".cs" else raw
            if path.suffix == ".xaml":
                # XML 命名空間是識別字、不會連線
                code = re.sub(r'xmlns(?::\w+)?="[^"]*"', "", code)
            rel = path.relative_to(root.parent)
            for pattern in FORBIDDEN:
                for m in re.finditer(pattern, code):
                    problems.append(f"{rel}: 不允許 {m.group(0)}")
            if path.suffix == ".cs" and path.name not in PROCESS_ALLOWED and PROCESS.search(code):
                problems.append(f"{rel}: 只有 SystemServices.cs 可以啟動其他程式")
            if path.suffix == ".csproj" and "PackageReference" in code:
                problems.append(f"{rel}: 不允許 PackageReference（App 與 UsageCore 不帶第三方套件）")
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
