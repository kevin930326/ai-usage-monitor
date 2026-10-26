#!/usr/bin/env python3
"""Windows App 的發布檔（ADR-0015 第 8 節）：x64 與 ARM64 各一個自含式 zip（不需要另外安裝 .NET），以及 SHA256SUMS-windows。

用法：scripts/package-windows-app.py --version <版本> --out <資料夾> [--rid win-x64] [--rid win-arm64]

- 以 Release、自含式（--self-contained）、不產生除錯符號（DebugType=none）建置 windows/src/AIUsageMonitor.Windows，
  版本寫進組件（-p:Version）。Mac、Linux 上也能建置（EnableWindowsTargeting），release.yml 在 Windows runner 建置。
- 打包前檢查：只有 Release 版的組件（不含 .pdb、測試組件、Debug 專用字串，windows/tools/check-no-network.py --release）、
  有 AIUsageMonitor.exe 與 .NET 執行環境、組件版本與 --version 相同。
- zip 裡是一個 AIUsageMonitor 資料夾；檔案依名稱排序、時間固定。
- SHA256SUMS-windows：每個 zip 一行（`sha256sum -c` 的格式）。Mac 的發布檔有自己的 SHA256SUMS，兩份分開才不會互相覆蓋。
只寫 --out：不上傳、不建立 tag 或 GitHub Release。
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "windows" / "src" / "AIUsageMonitor.Windows"
RIDS = ("win-x64", "win-arm64")
FIXED_TIME = (2020, 1, 1, 0, 0, 0)
# 發布檔不該有的檔案：除錯符號、測試組件與測試框架
FORBIDDEN_FILES = re.compile(r"(?i)\.pdb$|tests?\.dll$|^xunit|^Microsoft\.TestPlatform|^testhost")


def check_no_network():
    spec = importlib.util.spec_from_file_location("check_no_network", ROOT / "windows" / "tools" / "check-no-network.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def publish(rid: str, version: str, out: Path) -> None:
    command = [
        "dotnet", "publish", str(PROJECT), "-c", "Release", "-r", rid, "--self-contained", "true",
        f"-p:Version={version}", "-p:DebugType=none", "-p:DebugSymbols=false", "-p:ContinuousIntegrationBuild=true",
        "-o", str(out), "--nologo", "-v", "quiet",
    ]
    subprocess.run(command, cwd=ROOT, check=True)


def assembly_version(folder: Path) -> str | None:
    """AIUsageMonitor.dll 的 AssemblyInformationalVersion（UTF-8 存在 metadata 的 blob；不載入組件）"""
    data = (folder / "AIUsageMonitor.dll").read_bytes()
    # 屬性值是「長度＋UTF-8」，前面是屬性的 prolog 0x01 0x00；SDK 會在版本後面加 +<commit>，這裡只取 + 之前
    for m in re.finditer(rb"\x01\x00(.)([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?(?:\+[0-9A-Za-z.]+)?)", data):
        if m.group(1)[0] == len(m.group(2)):
            return m.group(2).decode().split("+", 1)[0]
    return None


def verify(folder: Path, version: str) -> list[str]:
    problems = []
    for name in ("AIUsageMonitor.exe", "AIUsageMonitor.dll", "AIUsageMonitor.Core.dll", "coreclr.dll", "PresentationFramework.dll"):
        if not (folder / name).is_file():
            problems.append(f"{folder.name}: 缺少 {name}（不是自含式的完整建置？）")
    for path in folder.rglob("*"):
        if path.is_file() and FORBIDDEN_FILES.search(path.name):
            problems.append(f"{folder.name}: 不該有 {path.relative_to(folder)}")
    problems += [f"{folder.name}: {p}" for p in check_no_network().check_release(folder)]
    found = assembly_version(folder)
    if found != version:
        problems.append(f"{folder.name}: 組件版本是 {found}，應該是 {version}")
    return problems


def build_zip(folder: Path, dest: Path) -> None:
    files = sorted(p for p in folder.rglob("*") if p.is_file())
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for path in files:
            info = zipfile.ZipInfo("AIUsageMonitor/" + path.relative_to(folder).as_posix(), FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, path.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--rid", action="append", choices=RIDS, help="預設兩個都建置")
    args = parser.parse_args()
    version = args.version.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", version):
        print(f"版本格式不對：{version}", file=sys.stderr)
        return 2
    args.out.mkdir(parents=True, exist_ok=True)
    sums = []
    with tempfile.TemporaryDirectory(prefix="aum-win-publish-") as tmp:
        for rid in args.rid or RIDS:
            folder = Path(tmp) / rid
            publish(rid, version, folder)
            problems = verify(folder, version)
            if problems:
                print("\n".join(problems), file=sys.stderr)
                return 1
            name = f"AIUsageMonitor-windows-{rid.removeprefix('win-')}-{version}.zip"
            build_zip(folder, args.out / name)
            sha = hashlib.sha256((args.out / name).read_bytes()).hexdigest()
            sums.append(f"{sha}  {name}\n")
            print(f"{name}  {sha}")
            shutil.rmtree(folder)
    (args.out / "SHA256SUMS-windows").write_text("".join(sums), encoding="ascii", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
