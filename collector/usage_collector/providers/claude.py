"""Claude provider（ADR-0006）。

執行未修改的 Claude Code：`claude -p /usage` 印出額度，`claude auth status --json` 提供方案名稱。
收集器不讀取 Claude 的登入資訊、不持有 token、不直接呼叫 Anthropic 的端點；token 由 Claude Code 自己管理與續期。
`/usage` 在 `-p` 模式是本機指令，不呼叫模型、不消耗額度。

`/usage` 的文字格式沒有文件保證：只取認得的額度行，有「Current …」行認不得時整個視為格式改變，
不猜測、不把缺少的欄位當成 0%。輸出可能含個人資訊，一律不寫進日誌或快照。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .. import paths
from ..models import ProviderError, ProviderUsage, Window, parse_pct

# --safe-mode 略過 hooks、外掛、MCP 與自訂指令；--no-session-persistence 不在 `claude --resume` 留下紀錄
USAGE_ARGS = ("-p", "/usage", "--safe-mode", "--no-session-persistence", "--output-format", "json")
STATUS_ARGS = ("auth", "status", "--json")
TIMEOUT = 30  # 秒；正常約 1.5 秒

FORMAT_CHANGED = "Claude Code 的 /usage 輸出格式已改變，請更新收集器"

# 例：Current session: 45% used · resets Oct 22 at 1am (Asia/Taipei)
LINE_RE = re.compile(r"^Current (?:session|week \((?P<scope>[^)]+)\)): (?P<pct>\d+(?:\.\d+)?)% used"
                     r"(?: · resets (?P<reset>.+))?$")
# 例：Oct 22 at 1am、Jan 2, 2027 at 11:30pm；舊版 ICU 用逗號而不是 at。不是今年才會顯示年份
RESET_RE = re.compile(r"^(?P<month>[A-Z][a-z]{2}) (?P<day>\d{1,2})(?:, (?P<year>\d{4}))?(?: at|,) "
                      r"(?P<hour>\d{1,2})(?::(?P<minute>\d{2}))?\s?(?P<ampm>[ap]m)(?: \((?P<tz>[^)]+)\))?$",
                      re.IGNORECASE)
MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")


def resolve_claude_path(config_path: Path | None = None) -> str | None:
    """安裝腳本把偵測到的完整路徑寫進 config.json 的 claude_path（launchd 的 PATH 找不到 claude）；
    手動執行時退回 PATH。"""
    try:
        path = json.loads((config_path or paths.CONFIG_PATH).read_text()).get("claude_path")
    except (FileNotFoundError, json.JSONDecodeError, AttributeError):
        path = None
    path = path or shutil.which("claude")
    return path if path and os.access(path, os.X_OK) else None


def run_claude(path: str, args: tuple[str, ...]) -> subprocess.CompletedProcess:
    # 暫存資料夾：不載入任何專案的 CLAUDE.md；stdin 關閉：-p 在 stdin 是開著的管線時會等待輸入
    with tempfile.TemporaryDirectory(prefix="aum-claude-") as cwd:
        try:
            return subprocess.run([path, *args], cwd=cwd, stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            raise ProviderError(f"Claude Code 執行逾時（{TIMEOUT:g} 秒）") from None
        except OSError:
            raise ProviderError("無法執行 claude，重新執行 scripts/install-launchd.sh") from None


def usage_text(stdout: str) -> str:
    """`--output-format json` 的 `result` 就是 /usage 的文字；不是 JSON 時（舊版或參數被忽略）直接當文字。"""
    try:
        body = json.loads(stdout)
    except json.JSONDecodeError:
        return stdout
    if not isinstance(body, dict) or not isinstance(body.get("result"), str):
        raise ProviderError(FORMAT_CHANGED)
    if body.get("is_error"):
        raise ProviderError("Claude Code 執行 /usage 時回報錯誤")
    return body["result"]


def parse_reset(text: str, now: datetime) -> datetime:
    m = RESET_RE.match(text.strip())
    if not m:
        raise ProviderError(FORMAT_CHANGED)
    try:
        # Claude Code 以系統時區顯示並附上時區名稱；沒有附上時同樣用本機時區
        tz = ZoneInfo(m["tz"]) if m["tz"] else now.astimezone().tzinfo
    except (ZoneInfoNotFoundError, ValueError):
        raise ProviderError(FORMAT_CHANGED) from None
    if not 1 <= int(m["hour"]) <= 12:
        raise ProviderError(FORMAT_CHANGED)  # 12 小時制沒有 0am／13pm
    hour = int(m["hour"]) % 12 + (12 if m["ampm"].lower() == "pm" else 0)
    year = int(m["year"]) if m["year"] else now.astimezone(tz).year
    try:
        return datetime(year, MONTHS.index(m["month"].lower()) + 1, int(m["day"]), hour,
                        int(m["minute"] or 0), tzinfo=tz)
    except ValueError:
        raise ProviderError(FORMAT_CHANGED) from None


def window_for(scope: str | None) -> tuple[str, str, bool]:
    """額度行 → (統一 id, 顯示名稱, hidden)。各模型的每週額度（FR-14）列為 hidden。"""
    if scope is None:
        return "five_hour", "5 小時", False
    if scope == "all models":
        return "weekly", "每週", False
    name = scope.removesuffix(" only")
    return f"weekly_{name.lower()}", f"每週 {name}", True


def parse(text: str, plan: str | None, now: datetime | None = None) -> ProviderUsage:
    now = now or datetime.now(timezone.utc)
    windows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("Current "):
            continue
        m = LINE_RE.match(line)
        if not m:
            raise ProviderError(FORMAT_CHANGED)
        wid, label, hidden = window_for(m["scope"])
        resets_at = parse_reset(m["reset"], now) if m["reset"] else None
        try:
            pct = parse_pct(float(m["pct"]))  # 位數多到變成 inf 時同樣視為格式改變，不寫出不合法的 JSON
        except ProviderError:
            raise ProviderError(FORMAT_CHANGED) from None
        windows.append(Window(wid, label, pct, resets_at, hidden=hidden))

    if not any(w.id in ("five_hour", "weekly") for w in windows):
        if windows:
            raise ProviderError(FORMAT_CHANGED)
        if text.lstrip().startswith("Total cost:"):
            # 沒有用訂閱登入時，/usage 只印出這次執行的成本摘要
            raise ProviderError("尚未用 Claude 訂閱登入 Claude Code，請在終端機執行 claude 並 /login")
        if "to power your Claude Code usage" in text:
            raise ProviderError("Claude Code 暫時查不到額度")
        raise ProviderError(FORMAT_CHANGED)
    return ProviderUsage(plan=plan, windows=windows)


def read_plan(path: str) -> str | None:
    """只取 subscriptionType；同一份輸出裡的 email、組織等欄位不保留。查不到不算錯誤。"""
    try:
        result = run_claude(path, STATUS_ARGS)
        plan = json.loads(result.stdout).get("subscriptionType")
    except (ProviderError, json.JSONDecodeError, AttributeError):
        return None
    return plan.title() if isinstance(plan, str) and plan else None


def fetch() -> ProviderUsage:
    path = resolve_claude_path()
    if not path:
        raise ProviderError("找不到 claude 執行檔，重新執行 scripts/install-launchd.sh")
    result = run_claude(path, USAGE_ARGS)
    if result.returncode != 0:
        # stderr 可能含個人資訊，不帶出去
        raise ProviderError(f"Claude Code 執行 /usage 失敗（結束碼 {result.returncode}）")
    usage = parse(usage_text(result.stdout), None)
    usage.plan = read_plan(path)
    return usage
