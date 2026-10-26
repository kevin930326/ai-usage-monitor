#!/usr/bin/env python3
"""README 的截圖（docs/images/）是否齊全、是否依目前的截圖基準（apple/Snapshots/）產生。

    python3 scripts/check-readme-images.py                    # verify-all、CI
    python3 scripts/check-readme-images.py --strict           # 截圖比基準舊也算失敗
    python3 scripts/check-readme-images.py --record <圖片>...  # scripts/update-readme-images.sh 產生圖片後記錄

- 檢查 README.md 與 README.zh-TW.md（後者有才檢查）引用的圖片。
- 失敗（結束碼 1）：README 引用的圖片不存在、沒有列在 docs/images/SOURCES.tsv，或表中的圖片、基準不存在。
- 提醒（結束碼 0，--strict 時 1）：圖片不是依目前的基準產生的。update-readme-images.sh 每產生一張圖，就把當時基準的
  SHA-256 記在 docs/images/BASELINES.tsv；基準的內容之後改了（含未提交的修改）才提醒。重新產生後圖片沒有變化時，
  只有 BASELINES.tsv 會變，提交它就不再提醒（以前比提交時間，內容相同、沒有東西可提交時提醒消不掉）。
  看到提醒時執行 scripts/update-readme-images.sh，檢查圖片後連同 BASELINES.tsv 一起提交。
"""
from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = "docs/images/SOURCES.tsv"
RECORDS = "docs/images/BASELINES.tsv"
RECORDS_HEADER = "# 圖片\t產生時的基準\t基準的 SHA-256（scripts/update-readme-images.sh 寫入，不要手改）\n"
READMES = ("README.md", "README.zh-TW.md")  # 英文版在前；繁體中文版有才檢查
def read_sources(root: Path) -> dict[str, str]:
    """圖片 → 對應的基準（沒有時是 "-"）"""
    mapping: dict[str, str] = {}
    for line in (root / SOURCES).read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) not in (4, 5):  # 第 5 欄「後製」可省略
            raise ValueError(f"{SOURCES} 的格式不對（要 4 或 5 欄，以 tab 分隔）：{line}")
        mapping[fields[0]] = fields[2]
    return mapping


def readme_images(root: Path) -> dict[str, list[str]]:
    """圖片 → 引用它的 README（README.md 必須存在；其他語言版本有才檢查）"""
    images: dict[str, list[str]] = {}
    for name in READMES:
        path = root / name
        if name != READMES[0] and not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for image in sorted(set(re.findall(r"docs/images/([\w.\-]+\.(?:png|gif|jpe?g|svg|webp))", text))):
            images.setdefault(image, []).append(name)
    return dict(sorted(images.items()))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_records(root: Path) -> dict[str, tuple[str, str]]:
    """圖片 → （產生時的基準、基準的 SHA-256）"""
    path = root / RECORDS
    if not path.is_file():
        return {}
    records: dict[str, tuple[str, str]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if line.startswith("#") or len(fields) != 3:
            continue
        records[fields[0]] = (fields[1], fields[2])
    return records


def record(root: Path, images: list[str]) -> list[str]:
    """記下這些圖片是依目前的基準產生的；回傳錯誤"""
    mapping = read_sources(root)
    records = read_records(root)
    errors: list[str] = []
    for image in images:
        baseline = mapping.get(image)
        if baseline is None:
            errors.append(f"docs/images/{image} 沒有列在 {SOURCES}")
        elif baseline == "-":
            records.pop(image, None)
        elif not (root / baseline).is_file():
            errors.append(f"{SOURCES} 列的基準 {baseline} 不存在")
        else:
            records[image] = (baseline, sha256(root / baseline))
    if not errors:
        lines = [f"{image}\t{baseline}\t{digest}\n" for image, (baseline, digest) in sorted(records.items())]
        (root / RECORDS).write_text(RECORDS_HEADER + "".join(lines), encoding="utf-8")
    return errors


def check(root: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    mapping = read_sources(root)
    referenced = readme_images(root)
    for image, readmes in referenced.items():
        if not (root / "docs/images" / image).is_file():
            errors.append(f"{'、'.join(readmes)} 引用的 docs/images/{image} 不存在")
        if image not in mapping:
            errors.append(f"docs/images/{image} 沒有列在 {SOURCES}（不知道怎麼重新產生）")
    for image, baseline in mapping.items():
        if not (root / "docs/images" / image).is_file():
            errors.append(f"{SOURCES} 列的 docs/images/{image} 不存在")
        if baseline != "-" and not (root / baseline).is_file():
            errors.append(f"{SOURCES} 列的基準 {baseline} 不存在")
        if image not in referenced:
            warnings.append(f"docs/images/{image} 列在 {SOURCES}，但 README 沒有引用")
    if errors:
        return errors, warnings
    records = read_records(root)
    for image, baseline in mapping.items():
        if baseline == "-" or image not in referenced:
            continue
        if records.get(image) != (baseline, sha256(root / baseline)):
            warnings.append(f"docs/images/{image} 不是依目前的截圖基準 {baseline} 產生的：執行 scripts/update-readme-images.sh 更新")
    return errors, warnings


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    root = Path(os.environ.get("README_IMAGES_ROOT", ROOT))
    if argv[:1] == ["--record"]:
        errors = record(root, argv[1:])
        for message in errors:
            print(f"錯誤：{message}")
        return 1 if errors else 0
    errors, warnings = check(root)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for message in errors:
        print(f"::error::{message}" if annotate else f"錯誤：{message}")
    for message in warnings:
        print(f"::warning::{message}" if annotate else f"提醒：{message}")
    if not errors and not warnings:
        print(f"README 的截圖齊全，都依目前的截圖基準產生（{len(read_sources(root))} 張）")
    return 1 if errors or (strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
