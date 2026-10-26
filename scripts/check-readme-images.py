#!/usr/bin/env python3
"""README 的截圖（docs/images/）是否齊全、是否比對應畫面的截圖基準（apple/Snapshots/）舊。

    python3 scripts/check-readme-images.py            # verify-all、CI
    python3 scripts/check-readme-images.py --strict   # 截圖比基準舊也算失敗

- 檢查 README.md 與 README.zh-TW.md（後者有才檢查）引用的圖片。
- 失敗（結束碼 1）：README 引用的圖片不存在、沒有列在 docs/images/SOURCES.tsv，或表中的圖片、基準不存在。
- 提醒（結束碼 0，--strict 時 1）：圖片最後一次提交早於對應基準的最後一次提交，或基準有未提交的修改而圖片沒有。
  看到提醒時執行 scripts/update-readme-images.sh，檢查圖片後一起提交。
- 時間以 git 的提交時間比較；有未提交修改的檔案算「現在」。淺層 clone（CI 的預設）沒有歷史，會提示改用完整歷史；
  git 查詢失敗時也只提示「沒有比較新舊」，不說通過（--strict 時失敗）。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = "docs/images/SOURCES.tsv"
READMES = ("README.md", "README.zh-TW.md")  # 英文版在前；繁體中文版有才檢查
NOW = float("inf")


class GitError(Exception):
    """git 查詢失敗（不是 git 資料夾、git 不能用）；訊息不含 stderr，避免印出路徑"""


def git(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    except OSError as e:
        raise GitError(f"git {args[0]}") from e
    if result.returncode != 0:
        raise GitError(f"git {args[0]}（結束碼 {result.returncode}）")
    return result.stdout.strip()


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


def changed_at(root: Path, path: str) -> float:
    """最後一次提交的時間；有未提交的修改或還沒提交過時算現在"""
    if git(root, "status", "--porcelain", "--", path):
        return NOW
    stamp = git(root, "log", "-1", "--format=%ct", "--", path)
    return float(stamp) if stamp else NOW


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
    try:
        if git(root, "rev-parse", "--is-shallow-repository") == "true":
            warnings.append("淺層 clone 沒有提交歷史，無法比較截圖新舊（CI 的 checkout 要設 fetch-depth: 0）")
            return errors, warnings
        for image, baseline in mapping.items():
            if baseline == "-" or image not in referenced:
                continue
            if changed_at(root, baseline) > changed_at(root, f"docs/images/{image}"):
                warnings.append(f"docs/images/{image} 比截圖基準 {baseline} 舊：執行 scripts/update-readme-images.sh 更新")
    except GitError as e:
        warnings.append(f"無法查詢提交歷史（{e}），沒有比較截圖新舊")
    return errors, warnings


def main(argv: list[str]) -> int:
    strict = "--strict" in argv
    root = Path(os.environ.get("README_IMAGES_ROOT", ROOT))
    errors, warnings = check(root)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for message in errors:
        print(f"::error::{message}" if annotate else f"錯誤：{message}")
    for message in warnings:
        print(f"::warning::{message}" if annotate else f"提醒：{message}")
    if not errors and not warnings:
        print(f"README 的截圖齊全，都不比截圖基準舊（{len(read_sources(root))} 張）")
    return 1 if errors or (strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
