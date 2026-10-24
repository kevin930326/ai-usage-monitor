#!/usr/bin/env python3
"""示範、截圖與量測用的環境變數（`"AUM_…"` 字串）只能出現在 `#if DEBUG` 分支裡，
Release 才不會因為設了環境變數就換成假資料或改變行為（verify-all 的 `debug-env-source`）。

- 檢查 apple/ 下的 .swift（不含 Tests/）的字串字面值，略過 `//` 與 `/* */` 註解；註解或多行字串裡的 `#if` 不算。
- 條件一定蘊含 DEBUG 的分支才算（`DEBUG`、`DEBUG && os(iOS)`、`(DEBUG && A) || (DEBUG && B)`），
  以及 `#if !DEBUG` 的 `#else`；`DEBUG && A || B` 這類 Release 也可能成立的條件不算。巢狀時任何一層是 DEBUG 即可。
- 例外（Release 也要讀）：`AUM_TESTING`（測試環境的防護旗標，見 UsageFileLocator）。

用法：scripts/check-debug-env.py [repo 根目錄]；有違規時列出「檔案:行 名稱」並以 1 結束。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ALLOWED = {"AUM_TESTING"}
LITERAL = re.compile(r'"(AUM_[A-Z0-9_]+)"')
DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b\s*(.*)$")
TOKEN = re.compile(r"\s*(&&|\|\||!|\(|\)|[A-Za-z_][A-Za-z0-9_]*(?:\([^()]*\))?)")


def implies_debug(cond: str) -> bool:
    """條件成立時一定是 DEBUG：`DEBUG`、`A && B`（任一邊蘊含）、`A || B`（兩邊都蘊含）、括號。
    `!`、看不懂的寫法一律當成不是（保守：寧可多報）。"""
    tokens, pos = [], 0
    while pos < len(cond):
        m = TOKEN.match(cond, pos)
        if not m or not m.group(1):
            return False
        tokens.append(m.group(1))
        pos = m.end()
    index = 0

    def peek() -> str | None:
        return tokens[index] if index < len(tokens) else None

    def take() -> str:
        nonlocal index
        index += 1
        return tokens[index - 1]

    def disjunction() -> bool | None:
        value = conjunction()
        while value is not None and peek() == "||":
            take()
            right = conjunction()
            value = None if right is None else value and right
        return value

    def conjunction() -> bool | None:
        value = atom()
        while value is not None and peek() == "&&":
            take()
            right = atom()
            value = None if right is None else value or right
        return value

    def atom() -> bool | None:
        token = peek()
        if token is None:
            return None
        take()
        if token == "(":
            value = disjunction()
            if peek() != ")":
                return None
            take()
            return value
        if token == "!":
            return False if atom() is not None else None
        if token in ("&&", "||", ")"):
            return None
        return token == "DEBUG"

    result = disjunction()
    return bool(result) and index == len(tokens)


def code_lines(text: str) -> list[tuple[str, bool]]:
    """每一行去掉註解後的程式碼（字串字面值保留），以及這行開頭是不是程式碼
    （不在區塊註解或多行字串裡；只有這樣的行才可能是條件編譯指令）。支援巢狀區塊註解與三個引號的多行字串。"""
    result = []
    depth = 0          # 區塊註解的巢狀層數
    multiline = False  # 在 \"\"\" 字串裡
    for line in text.splitlines():
        starts_in_code = depth == 0 and not multiline
        out, i, in_string = [], 0, False
        while i < len(line):
            ch, two, three = line[i], line[i:i + 2], line[i:i + 3]
            if depth:
                if two == "/*":
                    depth += 1
                    i += 2
                elif two == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
                continue
            if multiline:
                if three == '"""':
                    multiline = False
                    out.append(three)
                    i += 3
                else:
                    out.append(ch)
                    i += 1
                continue
            if in_string:
                out.append(ch)
                if ch == "\\" and i + 1 < len(line):
                    out.append(line[i + 1])
                    i += 2
                    continue
                if ch == '"':
                    in_string = False
                i += 1
                continue
            if three == '"""':
                multiline = True
                out.append(three)
                i += 3
            elif ch == '"':
                in_string = True
                out.append(ch)
                i += 1
            elif two == "//":
                break
            elif two == "/*":
                depth = 1
                i += 2
            else:
                out.append(ch)
                i += 1
        result.append(("".join(out), starts_in_code))
    return result


def violations(path: Path) -> list[tuple[int, str]]:
    stack: list[list] = []  # 每層 [目前分支是 DEBUG, 這個 #if 的條件]
    found = []
    for n, (code, starts_in_code) in enumerate(code_lines(path.read_text(encoding="utf-8")), 1):
        m = DIRECTIVE.match(code) if starts_in_code else None
        if m:
            kind, cond = m.group(1), m.group(2).strip()
            if kind == "if":
                stack.append([implies_debug(cond), cond])
            elif kind == "elseif" and stack:
                stack[-1][0] = implies_debug(cond)
            elif kind == "else" and stack:
                stack[-1][0] = stack[-1][1].replace(" ", "") == "!DEBUG"
            elif kind == "endif" and stack:
                stack.pop()
            continue
        if any(frame[0] for frame in stack):
            continue
        for name in LITERAL.findall(code):
            if name not in ALLOWED:
                found.append((n, name))
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent
    bad = []
    for path in sorted((root / "apple").rglob("*.swift")):
        rel = path.relative_to(root)
        if "Tests" in rel.parts or "build" in rel.parts or ".build" in rel.parts:
            continue
        bad += [f"{rel}:{n} {name}" for n, name in violations(path)]
    for line in bad:
        print(line)
    if bad:
        print(f"示範用環境變數不在 #if DEBUG 裡：{len(bad)} 處")
        return 1
    print("示範用環境變數都在 #if DEBUG 裡")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
