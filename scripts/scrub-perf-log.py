#!/usr/bin/env python3
"""量測紀錄存檔前去掉路徑（隱私底線：不存完整路徑，ADR-0016 第 6 節，Codex #170 第二、三輪 C-01）。

    scrub-perf-log.py sample <sample 的原始輸出> <輸出>   只留 Call graph 到 Binary Images 之前（函式名稱與次數）
    scrub-perf-log.py log <app.log>                       就地處理

白名單：每一行從第一個「/」或「~/」起到行尾整個拿掉（路徑裡有空白、括號、中文也一樣），sample 的每一行先拿掉位址後面的原始碼位置。
"""
import re
import sys

CUT = re.compile(r"(?:~/|/).*$")
SOURCE = re.compile(r"(\[0x[0-9a-f]+\]).*$")


def scrub_line(line: str) -> str:
    return CUT.sub("", line).rstrip()


def scrub_sample(text: str) -> str:
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith("Call graph:"))
    except StopIteration:
        return "（sample 沒有 Call graph）\n"
    kept = []
    for line in lines[start:]:
        if line.startswith("Binary Images:"):
            break
        kept.append(scrub_line(SOURCE.sub(r"\1", line)))
    return "\n".join(kept) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "sample":
        with open(argv[2], errors="replace") as f:
            text = f.read()
        with open(argv[3], "w") as f:
            f.write(scrub_sample(text))
        return 0
    if len(argv) == 3 and argv[1] == "log":
        with open(argv[2], errors="replace") as f:
            lines = f.read().splitlines()
        with open(argv[2], "w") as f:
            f.write("".join(scrub_line(line) + "\n" for line in lines))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
