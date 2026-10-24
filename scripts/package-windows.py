#!/usr/bin/env python3
"""Windows 收集器的發布檔（FR-48、ADR-0013 第 7 節）：AIUsageMonitor-collector-<版本>.zip 與寫好版本、SHA-256 的 install.ps1。

用法：scripts/package-windows.py --version <版本> --out <資料夾>

- zip 只放 Windows 執行需要的檔案（collector/usage_collector、collector/scripts/update-config.py、collector/windows/*.ps1），
  不含測試、__pycache__ 與 macOS 專用的腳本；以 git 追蹤的檔案為準，檔案時間固定，同一個 commit 產出相同的 zip。
- install.ps1 的 __VERSION__、__ZIP_SHA256__ 各取代恰好一次（scripts/build-release.sh 以同樣方式處理 install.sh）。
只寫 --out：不上傳、不建立 tag 或 GitHub Release。
"""
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INCLUDE = ("collector/usage_collector/", "collector/scripts/update-config.py", "collector/windows/")
FIXED_TIME = (2020, 1, 1, 0, 0, 0)


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "ls-files", "collector"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    files = [f for f in out.splitlines() if f.startswith(INCLUDE) and "__pycache__" not in f]
    if not any(f.endswith("usage_collector/__main__.py") for f in files):
        raise SystemExit("找不到 collector/usage_collector/__main__.py")
    return sorted(files)


def build_zip(path: Path, files: list[str]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name in files:
            info = zipfile.ZipInfo(name, FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, (ROOT / name).read_bytes())


def write_installer(dest: Path, version: str, sha: str) -> None:
    text = (ROOT / "scripts" / "install.ps1").read_text(encoding="ascii")
    for placeholder, value in (("__VERSION__", version), ("__ZIP_SHA256__", sha)):
        # 宣告那一行恰好一次；其他地方（例如判斷有沒有取代過）不能出現
        declaration = f"'{placeholder}'"
        if text.count(declaration) != 1:
            raise SystemExit(f"install.ps1 的 {declaration} 應該恰好出現一次")
        text = text.replace(declaration, f"'{value}'")
    dest.write_text(text, encoding="ascii", newline="\r\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    version = args.version.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", version):
        print(f"版本格式不對：{version}", file=sys.stderr)
        return 2
    args.out.mkdir(parents=True, exist_ok=True)
    zip_path = args.out / f"AIUsageMonitor-collector-{version}.zip"
    build_zip(zip_path, tracked_files())
    sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    write_installer(args.out / "install.ps1", version, sha)
    print(f"{zip_path.name}  {sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
