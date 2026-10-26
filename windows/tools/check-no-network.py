#!/usr/bin/env python3
"""Windows App 與 UsageCore 不連網、不碰密鑰（ADR-0015 第 2 節）的靜態檢查。

- 原始碼不得出現網路（System.Net、HttpClient、Socket、WinHttp、WebSocket…）與認證（CredRead、PasswordVault…）的 API
- 啟動其他程式（Process.Start、ProcessStartInfo）只能在 SystemServices.cs（觸發收集器的 schtasks.exe）
- App 與 UsageCore 不得有 PackageReference（不帶第三方程式）
- 不得用 CompositionTarget.Rendering（每一格都會執行；動畫只用 DoubleAnimation，ADR-0015 第 7 節）
- 傳入 Release 版的執行檔（--release <資料夾>）時，另外確認不含 Debug 專用的字串（示範資料、截圖參數）

用法：python3 windows/tools/check-no-network.py [--release <publish 資料夾>]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "src" / "AIUsageMonitor.Windows", ROOT / "src" / "UsageCore"]

FORBIDDEN = [
    r"System\.Net\b", r"\bHttpClient\b", r"\bWebRequest\b", r"\bWebClient\b", r"\bSocket\b", r"\bTcpClient\b", r"\bUdpClient\b",
    r"\bWebSocket", r"WinHttp", r"wininet", r"\bDns\b", r"URLDownloadToFile", r"\bNamedPipe",
    r"\bCredRead", r"\bCredWrite", r"\bCredEnumerate", r"\bPasswordVault\b", r"\bProtectedData\b", r"advapi32",
    r"CompositionTarget\.Rendering",
]
PROCESS = re.compile(r"\bProcess\.Start\b|\bProcessStartInfo\b|\bShellExecute")
PROCESS_ALLOWED = {"SystemServices.cs"}
# Release 版不該有的字串（DebugTools.cs 的參數與示範資料）；.NET 的字串以 UTF-16LE 存放
DEBUG_STRINGS = ["--render", "--demo", "aum-demo-", "DebugTools", "DemoJson"]


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def check_sources() -> list[str]:
    problems = []
    for folder in SOURCES:
        for path in sorted(folder.rglob("*")):
            if path.suffix not in (".cs", ".xaml", ".csproj", ".props") or "obj" in path.parts or "bin" in path.parts:
                continue
            raw = path.read_text(encoding="utf-8")
            code = strip_comments(raw) if path.suffix == ".cs" else raw
            rel = path.relative_to(ROOT.parent)
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
    binaries = [p for p in folder.rglob("*") if p.suffix in (".dll", ".exe") and p.name.startswith(("AIUsageMonitor",))]
    if not binaries:
        return [f"{folder}: 找不到 AIUsageMonitor 的執行檔"]
    for path in binaries:
        data = path.read_bytes()
        for s in DEBUG_STRINGS:
            if s.encode("utf-16-le") in data or s.encode("utf-8") in data:
                problems.append(f"{path.name}: Release 版含有 Debug 專用的字串 {s!r}")
    return problems


def main(argv: list[str]) -> int:
    problems = check_sources()
    if "--release" in argv:
        problems += check_release(Path(argv[argv.index("--release") + 1]))
    for p in problems:
        print(p)
    print(f"check-no-network: {'OK' if not problems else f'{len(problems)} 個問題'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
