#!/usr/bin/env python3
"""Windows App 的圖示（windows/src/AIUsageMonitor.Windows/Assets/AppIcon.ico）：由 Mac App 圖示的 PNG 組成。

圖示本身由 scripts/render-app-icon.swift 產生（設計 skill 第 2 節，不要手改 PNG）；改了 Mac 的圖示後執行：

    python3 windows/tools/make-ico.py

ICO 的每個尺寸直接存 PNG（Windows Vista 以後支援）；Mac 沒有的 24、48 由 sips 從 64 縮小。只用 macOS 內建的 sips。
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apple/MacMenuBar/AIUsageMenuBar/Assets.xcassets/AppIcon.appiconset"
OUT = ROOT / "windows/src/AIUsageMonitor.Windows/Assets/AppIcon.ico"
SIZES = [16, 24, 32, 48, 64, 128, 256]


def png(size: int, tmp: Path) -> bytes:
    direct = SOURCE / f"AppIcon-{size}.png"
    if direct.exists():
        return direct.read_bytes()
    out = tmp / f"{size}.png"
    subprocess.run(["sips", "-z", str(size), str(size), str(SOURCE / "AppIcon-64.png"), "--out", str(out)],
                   check=True, capture_output=True)
    return out.read_bytes()


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        images = [png(s, Path(t)) for s in SIZES]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, data = b"", b""
    for size, image in zip(SIZES, images):
        dim = 0 if size >= 256 else size  # 0 代表 256
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(image), offset + len(data))
        data += image
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(header + entries + data)
    print(f"{OUT.relative_to(ROOT)}：{len(SIZES)} 個尺寸，{OUT.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
