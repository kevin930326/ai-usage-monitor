"""Token 統計（ADR-0009 第 3、4、7 節）：從本機 Claude Code 與 Codex CLI 的對話紀錄累加每日／每小時的 Token。

隱私（NFR-9）：
- 只列舉 ADR 列出的檔案（一般檔案，不跟隨符號連結）；不讀憑證、設定或其他檔案。
- 逐行先以位元組篩選，解析後立刻只取白名單欄位，其餘丟棄；不保留原始行或整個物件。
- 資料庫只存數字、時間、服務、正規化後的模型名稱與 ID；`file_key` 只用檔名中的 UUID。
- 日誌只記錄例外的類別名稱與檔案序號，不記錄檔名、路徑、行內容或例外訊息。
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import time
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from . import history, system
from .log import log
from .paths import CONFIG_PATH

MAX_LINE_BYTES = 4 * 1024 * 1024
SKIP_CHUNK_BYTES = 1024 * 1024  # 丟棄過長的行時每次讀多少（每段都扣預算）
CHUNK_BYTES = 64 * 1024 * 1024  # 每次執行最多處理的位元組（首次掃描分段）
CHUNK_SECONDS = 15.0
TASK_CAP_SECONDS = 6 * 3600  # Claude：超過 6 小時視為中斷，以 6 小時計
LAST_SEEN_REFRESH = 86400  # 沒有變化的檔案一天更新一次 last_seen
# 去重的時間窗（ADR-0014 第 1 節）：本機日期早於略過界 D（meta.seen_cutoff_day）的訊息、回應、任務與 Codex 累計差額
# 不計算也不記錄；D 每次執行最多前進一天到 SEEN_DAYS 天前、只進不退，首次掃描完成前不設定。
# 去重表只留 day >= D − 1 的列（多留一天吸收改時區後同一時間戳算出不同日期），每次最多刪 SEEN_PRUNE_ROWS 列
SEEN_DAYS = 90
SEEN_PRUNE_ROWS = 20_000
SEEN_TABLES = ("seen_ids", "seen_tasks", "file_tokens")

PROVIDERS = ("claude", "codex")
# 向量順序：input、cache_write、cache_read、output、reasoning（與資料表欄位相同）
TOKEN_FIELDS = ("input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens", "reasoning_tokens")
RECORD_KEYS = ("total_tokens", "best_day_tokens", "longest_task_seconds", "longest_streak_days",
               "total_tokens_cached", "best_day_tokens_cached")

_MODEL_RE = re.compile(r"^(claude-|gpt-|codex-|o[0-9])[a-z0-9._-]*$")
_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# 檔名只接受固定格式（file_key 會寫進資料庫，不能帶出專案或帳號名稱）：
# Claude 主紀錄 `<uuid>`、同一 session 的舊副本 `<uuid>.orphaned-…`／`<uuid>.superseded-…`、子代理 `agent-<hex>`
_CLAUDE_MAIN = re.compile(r"^(?P<uuid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
                          r"(?:\.(?:orphaned|superseded)-[0-9A-Za-z_]{1,40})?$")
_CLAUDE_SUBAGENT = re.compile(r"^agent-[0-9a-f]{1,64}$")
_DIGITS = {4: re.compile(r"^[0-9]{4}$"), 2: re.compile(r"^[0-9]{2}$")}

_CLAUDE_NEEDLES = (b'"user"',)
_CODEX_NEEDLES = (b'"token_usage_record"', b'"token_count"', b'"task_started"', b'"task_complete"', b'"turn_context"')


def main_tokens(vec) -> int:
    """顯示用的「Token」主數字 = input + cache_write + output（不含 cache_read、不另加 reasoning）。"""
    return vec[0] + vec[1] + vec[3]


def cached_tokens(vec) -> int:
    """含快取讀取的數字 = input + cache_write + cache_read + output（FR-60，個人紀錄的 *_cached 用）。"""
    return vec[0] + vec[1] + vec[2] + vec[3]


def normalize_model(value) -> str:
    """模型名稱白名單（第二層會上傳）：其他一律記為 other。"""
    if isinstance(value, str) and len(value) <= 64 and _MODEL_RE.match(value):
        return value
    return "other"


def _count(value) -> int:
    # bool 是 int 的子類別，要排除；負數與其他型別當 0
    return value if type(value) is int and value > 0 else 0


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def _epoch(value) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def _day_hour(ts: int) -> tuple[str, int]:
    # 掃描當下的本機時區（之後改時區不回頭重算）
    local = system.local_datetime(ts)
    return local.date().isoformat(), local.hour


# MARK: - 紀錄資料夾與檔案列舉


def log_dirs(config_path: Path | None = None, environ: Mapping[str, str] = os.environ) -> dict[str, Path]:
    """config.json 的 claude_config_dir／codex_home → 環境變數 → 預設的 ~/.claude、~/.codex。"""
    try:
        config = json.loads((config_path or CONFIG_PATH).read_text(encoding="utf-8"))
        if not isinstance(config, dict):
            config = {}
    except (OSError, ValueError):
        config = {}

    def pick(key: str, env: str, default: str) -> Path:
        value = config.get(key)
        if isinstance(value, str) and value:
            return Path(value).expanduser()
        if environ.get(env):
            return Path(environ[env]).expanduser()
        return Path.home() / default

    return {"claude": pick("claude_config_dir", "CLAUDE_CONFIG_DIR", ".claude"),
            "codex": pick("codex_home", "CODEX_HOME", ".codex")}


@dataclass
class LogFile:
    provider: str
    key: str
    path: str  # 只留在記憶體中：不寫進資料庫、日誌或輸出
    device: int
    inode: int
    size: int
    mtime: int


def _entries(path) -> list[os.DirEntry]:
    try:
        with os.scandir(path) as it:
            return sorted(it, key=lambda e: e.name)
    except OSError:
        return []


def _is_dir(entry: os.DirEntry) -> bool:
    try:
        return entry.is_dir(follow_symlinks=False)
    except OSError:
        return False


def _is_file(entry: os.DirEntry) -> bool:
    try:
        return entry.is_file(follow_symlinks=False)
    except OSError:
        return False


def _subdir(path, name: str) -> str | None:
    for entry in _entries(path):
        if entry.name == name and _is_dir(entry):
            return entry.path
    return None


def _file_key(provider: str, name: str, subagent: bool = False) -> str | None:
    """檔名中的 UUID（或子代理 ID）；格式不符的檔案不讀。"""
    stem = name[: -len(".jsonl")]
    if provider == "codex":
        ids = _UUID_RE.findall(stem)
        return "codex:" + ids[-1].lower() if ids else None
    if subagent:
        return f"claude:{stem}" if _CLAUDE_SUBAGENT.match(stem) else None
    return f"claude:{stem}" if _CLAUDE_MAIN.match(stem) else None


def _claude_candidates(root: Path) -> Iterable[tuple[os.DirEntry, bool]]:
    projects = _subdir(root, "projects")
    if projects is None:
        return
    for project in _entries(projects):
        if not _is_dir(project):
            continue
        for entry in _entries(project.path):
            if _is_file(entry) and entry.name.endswith(".jsonl"):
                yield entry, False  # <claude>/projects/*/<uuid>.jsonl（含 .orphaned-／.superseded- 副本）
            elif _is_dir(entry):
                subagents = _subdir(entry.path, "subagents")
                if subagents is None:
                    continue  # tool-results 等其他子資料夾不讀
                for sub in _entries(subagents):
                    if _is_file(sub) and sub.name.endswith(".jsonl"):
                        yield sub, True


def _codex_candidates(root: Path) -> Iterable[tuple[os.DirEntry, bool]]:
    def rollouts(path):
        for entry in _entries(path):
            if _is_file(entry) and entry.name.startswith("rollout-") and entry.name.endswith(".jsonl"):
                yield entry, False

    sessions = _subdir(root, "sessions")
    if sessions is not None:
        for year in _entries(sessions):
            if not (_is_dir(year) and _DIGITS[4].match(year.name)):
                continue
            for month in _entries(year.path):
                if not (_is_dir(month) and _DIGITS[2].match(month.name)):
                    continue
                for day in _entries(month.path):
                    if _is_dir(day) and _DIGITS[2].match(day.name):
                        yield from rollouts(day.path)
    archived = _subdir(root, "archived_sessions")
    if archived is not None:
        yield from rollouts(archived)


def list_files(dirs: Mapping[str, Path]) -> list[LogFile]:
    """只回傳 ADR-0009 第 3 節列出的檔案。"""
    files: dict[str, LogFile] = {}
    for provider, candidates in (("claude", _claude_candidates(dirs["claude"])),
                                 ("codex", _codex_candidates(dirs["codex"]))):
        for entry, subagent in candidates:
            key = _file_key(provider, entry.name, subagent)
            if key is None:
                continue
            try:
                st = system.entry_stat(entry)
            except OSError:
                continue
            if key in files:  # 同名的檔案出現在兩個地方（複製而不是搬移）
                if provider == "codex":
                    # token_count 來源沒有跨檔的 ID 可以去重，兩份都算會重複計入：只算先列到的那份（sessions 優先）
                    continue
                key = f"{key}#{st.st_ino}"  # Claude 以訊息 ID 跨檔去重，兩份都讀
            files[key] = LogFile(provider, key, entry.path, *system.file_identity(st), st.st_size, int(st.st_mtime))
    # 舊的先處理：首次掃描時第一次計入的日期、任務的先後都與實際順序一致
    return sorted(files.values(), key=lambda f: (f.mtime, f.key))


# MARK: - 加總


@dataclass
class Totals:
    """一次處理（一個檔案的一段）中累積的變化，最後一次寫進資料庫。"""
    device_id: str
    now: int
    buckets: dict = field(default_factory=dict)  # (provider, day, hour, model) → [5 tokens, tasks, seconds, longest]
    ledger: dict = field(default_factory=dict)  # Codex：(day, hour, model) → 5 tokens
    total: dict = field(default_factory=dict)  # provider → 主數字的變化（records.total_tokens）
    total_cached: dict = field(default_factory=dict)  # provider → 含快取讀取的變化（records.total_tokens_cached）
    longest: dict = field(default_factory=dict)  # provider → (seconds, day)
    seen_cutoff: str | None = None  # 略過界 D；None 時不略過（首次掃描）

    def too_old(self, ts: int) -> bool:
        """這個時間點的本機日期早於略過界：不計算也不記錄（它的去重列可能已經刪了，算了會重複）。"""
        return self.seen_cutoff is not None and _day_hour(ts)[0] < self.seen_cutoff

    def add(self, provider: str, day: str, hour: int, model: str, vec=(0, 0, 0, 0, 0),
            tasks: int = 0, seconds: int = 0, longest: int = 0, ledger: bool = False) -> None:
        b = self.buckets.setdefault((provider, day, hour, model), [0] * 8)
        for i, v in enumerate(vec):
            b[i] += v
        b[5] += tasks
        b[6] += seconds
        b[7] = max(b[7], longest)
        if ledger:
            led = self.ledger.setdefault((day, hour, model), [0] * 5)
            for i, v in enumerate(vec):
                led[i] += v
        self.total[provider] = self.total.get(provider, 0) + main_tokens(vec)
        self.total_cached[provider] = self.total_cached.get(provider, 0) + cached_tokens(vec)
        if longest > self.longest.get(provider, (0, None))[0]:
            self.longest[provider] = (longest, day)

    def flush(self, conn: sqlite3.Connection, file_key: str | None, cutoffs: tuple[str, str]) -> None:
        daily_cutoff, hourly_cutoff = cutoffs
        cols = ", ".join(TOKEN_FIELDS)
        # 個人紀錄用的每日數字（主數字、含快取讀取）：不套用保留期間（超過保留期間的舊紀錄也算進單日最高與連續天數）
        for table, measure in (("record_days", main_tokens), ("record_days_cached", cached_tokens)):
            record_days: dict[tuple[str, str], int] = {}
            for (provider, day, _, _), b in self.buckets.items():
                record_days[(day, provider)] = record_days.get((day, provider), 0) + measure(b)
            for (day, provider), delta in record_days.items():
                if delta > 0:
                    conn.execute(f"INSERT INTO {table} (day, provider, tokens) VALUES (?, ?, ?)"
                                 " ON CONFLICT (day, provider) DO UPDATE SET tokens = tokens + excluded.tokens",
                                 (day, provider, delta))
                elif delta < 0:
                    conn.execute(f"UPDATE {table} SET tokens = max(0, tokens + ?) WHERE day = ? AND provider = ?",
                                 (delta, day, provider))
        sets = ", ".join(f"{c} = max(0, {c} + excluded.{c})" for c in TOKEN_FIELDS + ("task_count", "task_seconds"))
        for (provider, day, hour, model), b in self.buckets.items():
            values = [max(0, v) for v in b[:7]] + [b[7], self.now]
            for table, key_cols, key_vals, cutoff in (
                    ("daily_tokens", "device_id, day, provider, model", [self.device_id, day, provider, model], daily_cutoff),
                    ("hourly_tokens", "device_id, day, hour, provider, model",
                     [self.device_id, day, hour, provider, model], hourly_cutoff)):
                if day < cutoff:
                    continue  # 已超過保留期間（首次掃描讀到的舊紀錄）：只計入 records
                if min(b[:7]) < 0:
                    # 扣除（Codex 重算）：只更新既有的列，不新增
                    conn.execute(
                        f"UPDATE {table} SET " + ", ".join(
                            f"{c} = max(0, {c} + ?)" for c in TOKEN_FIELDS + ("task_count", "task_seconds"))
                        + ", updated_at = ? WHERE " + " AND ".join(f"{k.strip()} = ?" for k in key_cols.split(",")),
                        [*b[:7], self.now, *key_vals])
                    continue
                conn.execute(
                    f"INSERT INTO {table} ({key_cols}, {cols}, task_count, task_seconds, longest_task_seconds, updated_at)"
                    f" VALUES ({', '.join('?' * (len(key_vals) + 9))})"
                    f" ON CONFLICT ({key_cols}) DO UPDATE SET {sets},"
                    " longest_task_seconds = max(longest_task_seconds, excluded.longest_task_seconds),"
                    " updated_at = excluded.updated_at",
                    [*key_vals, *values])
        if file_key is not None:
            for (day, hour, model), led in self.ledger.items():
                conn.execute(
                    f"INSERT INTO file_tokens (file_key, day, hour, model, {cols}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
                    f" ON CONFLICT (file_key, day, hour, model) DO UPDATE SET "
                    + ", ".join(f"{c} = {c} + excluded.{c}" for c in TOKEN_FIELDS),
                    [file_key, day, hour, model, *led])
        for base, totals in (("total_tokens", self.total), ("total_tokens_cached", self.total_cached)):
            for provider, delta in totals.items():
                if not delta:
                    continue
                for key in (base, f"{base}:{provider}"):
                    conn.execute("INSERT INTO records (key, value, day) VALUES (?, max(0, ?), NULL)"
                                 " ON CONFLICT (key) DO UPDATE SET value = max(0, value + excluded.value)"
                                 if delta > 0 else
                                 "UPDATE records SET value = max(0, value + ?) WHERE key = ?",
                                 (key, delta) if delta > 0 else (delta, key))
        for provider, (seconds, day) in self.longest.items():
            for key in ("longest_task_seconds", f"longest_task_seconds:{provider}"):
                _raise_record(conn, key, seconds, day)
        self.buckets.clear()
        self.ledger.clear()
        self.total.clear()
        self.total_cached.clear()
        self.longest.clear()


def _raise_record(conn: sqlite3.Connection, key: str, value: int, day: str | None) -> None:
    """個人紀錄只會變大（不隨保留期間刪除）；同樣大時記最早的那天（與讀取順序無關）。"""
    conn.execute("INSERT INTO records (key, value, day) VALUES (?, ?, ?)"
                 " ON CONFLICT (key) DO UPDATE SET value = excluded.value, day = excluded.day"
                 " WHERE excluded.value > records.value"
                 " OR (excluded.value = records.value AND excluded.day < records.day)", (key, value, day))


def _count_id(conn: sqlite3.Connection, totals: Totals, provider: str, msg_id: str, ts: int, model: str,
              vec, file_key: str | None = None, deltas: bool = True) -> None:
    """以 seen_ids 去重。第一次計入時記下歸屬（日期、小時、模型）與數值；之後再看到同一 ID 時，
    每個欄位都不小於已計入值才把差額加到第一次的歸屬（串流被切在兩次掃描之間）；否則忽略。"""
    if totals.too_old(ts):
        return
    row = conn.execute(f"SELECT day, hour, model, {', '.join(TOKEN_FIELDS)} FROM seen_ids"
                       " WHERE provider = ? AND id = ?", (provider, msg_id)).fetchone()
    ledger = provider == "codex"
    if row is None:
        day, hour = _day_hour(ts)
        conn.execute(f"INSERT INTO seen_ids (provider, id, day, hour, model, {', '.join(TOKEN_FIELDS)}, file_key)"
                     " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (provider, msg_id, day, hour, model, *vec, file_key))
        totals.add(provider, day, hour, model, vec, ledger=ledger)
        return
    if not deltas:
        return
    old = row[3:]
    if any(n < o for n, o in zip(vec, old)) or tuple(vec) == tuple(old):
        return
    delta = [n - o for n, o in zip(vec, old)]
    conn.execute(f"UPDATE seen_ids SET {', '.join(f'{c} = ?' for c in TOKEN_FIELDS)} WHERE provider = ? AND id = ?",
                 (*vec, provider, msg_id))
    totals.add(provider, row[0], row[1], row[2], delta, ledger=ledger)


def _count_task(conn: sqlite3.Connection, totals: Totals, provider: str, task_id: str, start: int,
                model: str, seconds: int) -> None:
    """以 seen_tasks 去重；同一任務之後變長（跨兩次掃描）時補上差額。任務歸到開始的那天與小時。"""
    if totals.too_old(start):
        return
    seconds = max(0, seconds)
    row = conn.execute("SELECT day, hour, model, seconds FROM seen_tasks WHERE provider = ? AND id = ?",
                       (provider, task_id)).fetchone()
    if row is None:
        day, hour = _day_hour(start)
        conn.execute("INSERT INTO seen_tasks (provider, id, day, hour, model, seconds) VALUES (?, ?, ?, ?, ?, ?)",
                     (provider, task_id, day, hour, model, seconds))
        totals.add(provider, day, hour, model, tasks=1, seconds=seconds, longest=seconds)
    elif seconds > row[3]:
        conn.execute("UPDATE seen_tasks SET seconds = ? WHERE provider = ? AND id = ?", (seconds, provider, task_id))
        totals.add(provider, row[0], row[1], row[2], seconds=seconds - row[3], longest=seconds)


# MARK: - 逐行處理


class _SwitchToRecord(Exception):
    """已用 token_count 的 Codex 檔案出現 token_usage_record：改用 record 從頭重算。"""


@dataclass
class FileState:
    offset: int = 0
    source: str | None = None
    last_total: list | None = None
    state: dict = field(default_factory=dict)
    # 正在丟棄一行過長的紀錄（跨次執行接著丟，不重讀）
    skipping: bool = False

    def state_json(self) -> str | None:
        state = {**self.state, "_skip": 1} if self.skipping else self.state
        return json.dumps(state) if state else None


@dataclass
class Counters:
    bad_lines: int = 0
    long_lines: int = 0
    failed_files: int = 0
    # 紀錄格式改變的偵測（ADR-0009 第 9 節）：讀了多少位元組、多少行通過位元組篩選、多少行計入了 Token
    bytes_read: int = 0
    candidate_lines: int = 0
    token_lines: int = 0

    def add(self, other: Counters) -> None:
        for name in ("bad_lines", "long_lines", "bytes_read", "candidate_lines", "token_lines"):
            setattr(self, name, getattr(self, name) + getattr(other, name))


# 格式可能已改變的門檻（ADR-0009 第 9 節，保守：寧可晚報，不要誤報）：
# 一次掃描至少 100 行候選、其中 ≥ 20% 無法解析；或讀了 ≥ 4 MB 新內容（不含丟棄的過長行）卻沒有任何一行計入 Token。
# 清除的證據較少就夠：候選 ≥ 20 行、有計入 Token、無法解析 < 20%。都不足時沿用上一次的判斷
FORMAT_MIN_CANDIDATES = 100
FORMAT_CLEAR_CANDIDATES = 20
FORMAT_BAD_RATIO = 0.2
FORMAT_MIN_BYTES = 4 * 1024 * 1024


def format_suspect(c: Counters) -> bool | None:
    """這次掃描是否像是紀錄格式改變了；證據不足時為 None（不改變上次的判斷）。"""
    mostly_bad = c.bad_lines >= c.candidate_lines * FORMAT_BAD_RATIO
    if c.candidate_lines >= FORMAT_MIN_CANDIDATES and mostly_bad:
        return True
    if c.bytes_read >= FORMAT_MIN_BYTES and c.token_lines == 0:
        return True
    if c.candidate_lines >= FORMAT_MIN_CANDIDATES or c.bytes_read >= FORMAT_MIN_BYTES:
        return False
    if c.candidate_lines >= FORMAT_CLEAR_CANDIDATES and c.token_lines > 0 and not mostly_bad:
        return False
    return None


def _claude_line(conn, totals: Totals, st: FileState, line: bytes, counters: Counters) -> None:
    if not ((b'"assistant"' in line and b'"usage"' in line) or b'"user"' in line):
        return
    counters.candidate_lines += 1
    try:
        obj = json.loads(line)
    except ValueError:
        counters.bad_lines += 1
        return
    if not isinstance(obj, dict):
        counters.bad_lines += 1
        return
    kind = obj.get("type")
    message = _dict(obj.get("message"))
    # 只取白名單欄位，之後不再使用 obj／message
    ts = _epoch(obj.get("timestamp"))
    sidechain = obj.get("isSidechain") is True
    if kind == "assistant":
        usage = message.get("usage")
        msg_id = message.get("id") if isinstance(message.get("id"), str) else obj.get("requestId")
        model = normalize_model(message.get("model"))
        vec = None
        if isinstance(usage, dict):
            vec = (_count(usage.get("input_tokens")), _count(usage.get("cache_creation_input_tokens")),
                   _count(usage.get("cache_read_input_tokens")), _count(usage.get("output_tokens")), 0)
        del obj, message, usage
        if ts is None or vec is None or not isinstance(msg_id, str) or not msg_id or len(msg_id) > 200:
            counters.bad_lines += 1
            return
        counters.token_lines += 1
        _count_id(conn, totals, "claude", msg_id, ts, model, vec)
        prompt = st.state.get("prompt")
        if not sidechain and isinstance(prompt, int):
            # 任務：真人提示 → 下一個真人提示之前最後一筆 assistant 行；以第一則回覆的 ID 當任務 ID
            task = st.state.setdefault("task", msg_id)
            st.state.setdefault("model", model)
            _count_task(conn, totals, "claude", task, prompt, st.state["model"],
                        min(ts - prompt, TASK_CAP_SECONDS))
    elif kind == "user":
        content = message.get("content")
        # 只判斷是否為 tool_result（型別），不讀文字
        tool_result = isinstance(content, list) and any(
            isinstance(c, dict) and c.get("type") == "tool_result" for c in content)
        meta = obj.get("isMeta") is True
        del obj, message, content
        if ts is not None and not sidechain and not meta and not tool_result:
            st.state = {"prompt": ts}


def _codex_usage(raw) -> list[int] | None:
    if not isinstance(raw, dict):
        return None
    return [_count(raw.get("input_tokens")), _count(raw.get("cached_input_tokens")),
            _count(raw.get("cache_write_input_tokens")), _count(raw.get("output_tokens")),
            _count(raw.get("reasoning_output_tokens"))]


def _codex_vec(raw: list[int]) -> tuple[int, int, int, int, int]:
    """OpenAI 的快取是輸入的子集、推理是輸出的子集（ADR-0009 第 4 節的正規化）。"""
    inp, cached, cache_write, out, reasoning = raw
    return (max(0, inp - cached - cache_write), cache_write, cached, out, reasoning)


def _codex_line(conn, totals: Totals, st: FileState, line: bytes, counters: Counters, file_key: str) -> None:
    if not any(n in line for n in _CODEX_NEEDLES):
        return
    counters.candidate_lines += 1
    try:
        obj = json.loads(line)
    except ValueError:
        counters.bad_lines += 1
        return
    if not isinstance(obj, dict):
        counters.bad_lines += 1
        return
    kind = obj.get("type")
    payload = _dict(obj.get("payload"))
    ts = _epoch(obj.get("timestamp"))
    if kind == "turn_context":
        st.state["model"] = normalize_model(payload.get("model"))
        return
    if kind == "token_usage_record":
        response_id = payload.get("response_id")
        usage = _codex_usage(payload.get("usage"))
        del obj, payload
        if st.source == "token_count":
            raise _SwitchToRecord
        if ts is None or usage is None or not isinstance(response_id, str) or not response_id or len(response_id) > 200:
            counters.bad_lines += 1
            return
        st.source = "record"
        counters.token_lines += 1
        # record 是完成後的最終數值：同一 ID 只計一次，不補差額
        _count_id(conn, totals, "codex", response_id, ts, st.state.get("model", "other"), _codex_vec(usage),
                  file_key=file_key, deltas=False)
        return
    if kind != "event_msg":
        return
    ptype = payload.get("type")
    if ptype == "token_count":
        info = payload.get("info")
        raw = _codex_usage(info.get("total_token_usage")) if isinstance(info, dict) else None
        del obj, payload, info
        if st.source == "record" or raw is None:
            return  # info 為 null 時略過
        if ts is None:
            counters.bad_lines += 1
            return
        st.source = "token_count"
        counters.token_lines += 1
        last = st.last_total
        st.last_total = raw
        if last is not None and len(last) == 5:
            delta = [n - o for n, o in zip(raw, last)]
            if any(d < 0 for d in delta):
                return  # compaction：以新值重新起算，不計入
        else:
            delta = raw
        if any(delta) and not totals.too_old(ts):  # 太舊的只接上累計值，不計入
            day, hour = _day_hour(ts)
            totals.add("codex", day, hour, st.state.get("model", "other"), _codex_vec(delta), ledger=True)
    elif ptype == "task_complete":
        turn_id = payload.get("turn_id")
        completed = payload.get("completed_at")
        started = payload.get("started_at")
        duration_ms = payload.get("duration_ms")
        del obj, payload
        if not isinstance(turn_id, str) or not turn_id or type(completed) is not int:
            counters.bad_lines += 1
            return
        if type(duration_ms) is int and duration_ms >= 0:
            seconds = duration_ms // 1000
        elif type(started) is int:
            seconds = completed - started
        else:
            counters.bad_lines += 1
            return
        start = started if type(started) is int else completed - seconds
        _count_task(conn, totals, "codex", turn_id, start, st.state.get("model", "other"), seconds)


# MARK: - 掃描


@dataclass
class Budget:
    bytes_left: int = CHUNK_BYTES
    deadline: float = field(default_factory=lambda: time.monotonic() + CHUNK_SECONDS)

    def exhausted(self) -> bool:
        return self.bytes_left <= 0 or time.monotonic() >= self.deadline


def _load_state(row) -> FileState:
    if row is None:
        return FileState()
    try:
        last_total = json.loads(row["last_total"]) if row["last_total"] else None
        state = json.loads(row["state"]) if row["state"] else {}
    except ValueError:
        last_total, state = None, {}
    state = state if isinstance(state, dict) else {}
    skipping = bool(state.pop("_skip", False))
    return FileState(offset=row["offset"], source=row["source"],
                     last_total=last_total if isinstance(last_total, list) else None, state=state, skipping=skipping)


def _reset_codex(conn: sqlite3.Connection, totals: Totals, file_key: str, cutoffs) -> None:
    """扣掉這個檔案在 file_tokens 的貢獻、清空帳本與它計入的回應 ID（ADR-0009 第 4 節的重算）。
    只扣略過界以後的日子：更早的事件重算時會被略過、不會加回來，那些日子的數字維持原樣（ADR-0014）。"""
    cols = ", ".join(TOKEN_FIELDS)
    for day, hour, model, *vec in conn.execute(
            f"SELECT day, hour, model, {cols} FROM file_tokens WHERE file_key = ? AND day >= ?",
            (file_key, totals.seen_cutoff or "")).fetchall():
        totals.add("codex", day, hour, model, [-v for v in vec])
    totals.flush(conn, None, cutoffs)
    conn.execute("DELETE FROM file_tokens WHERE file_key = ?", (file_key,))
    conn.execute("DELETE FROM seen_ids WHERE provider = 'codex' AND file_key = ?", (file_key,))


def _process(conn: sqlite3.Connection, f: LogFile, row, totals: Totals, budget: Budget,
             counters: Counters, cutoffs, switch: bool = False) -> int:
    """在一個交易內處理一個檔案從上次位置起的新內容。回傳處理後的 offset。
    `switch`：上一次嘗試遇到 _SwitchToRecord（交易已回復），這次先扣掉該檔的貢獻、改用 record 從頭重算。"""
    st = _load_state(row)
    # 先確認檔案打得開、而且是列舉到的那一個，才動統計：開不了或被換掉時這次什麼都不改（下次再處理）
    try:
        fd = os.open(f.path, system.OPEN_READ_FLAGS)
    except OSError:
        return st.offset
    with os.fdopen(fd, "rb") as fh:
        opened = os.fstat(fh.fileno())
        if system.file_identity(opened) != (f.device, f.inode):
            return st.offset
        # 大小與時間都用開檔後的 fstat：列舉在交易外，另一個收集器之後處理過新內容時，
        # 列舉時的 mtime 會比它寫下的舊，拿來比會把正常的附加誤判成改寫、整檔重算（審查 C-01）
        size, mtime = opened.st_size, int(opened.st_mtime)
        rewritten = row is not None and (
            (row["device"], row["inode"]) != (f.device, f.inode) or size < row["offset"] or mtime < row["mtime"])
        if switch:
            _reset_codex(conn, totals, f.key, cutoffs)
            st = FileState(source="record", state={"cutoff": totals.seen_cutoff or ""})
        elif row is None or rewritten:
            st = FileState()  # Claude 從頭重掃，以 seen_ids／seen_tasks 避免重複計入
            if f.provider == "codex":
                # 新檔案也先扣：scan_state 已過期刪除、但帳本還在的檔案再出現時不重複計入
                _reset_codex(conn, totals, f.key, cutoffs)
                st.state["cutoff"] = totals.seen_cutoff or ""
        # Codex 重算把開始時的略過界凍結到讀到檔尾（"" 表示不設界）：扣帳本與重讀用同一個值，
        # 分成幾輪讀、期間 D 前進（含升級那一輪從無到有）都和一次讀完相同（審查 C-01）
        if "cutoff" in st.state:
            totals.seen_cutoff = st.state["cutoff"] or None
        at_end = False
        fh.seek(st.offset)
        while not budget.exhausted():
            if st.skipping:
                # 丟棄過長的一行：每段都扣預算，到換行為止；預算用完時下次從這裡接著丟
                chunk = fh.readline(SKIP_CHUNK_BYTES)
                if not chunk:
                    at_end = True
                    break
                budget.bytes_left -= len(chunk)  # 不算進格式偵測的讀取量：貼上的圖片（base64）就會超過上限
                st.offset = fh.tell()
                if chunk.endswith(b"\n"):
                    st.skipping = False
                    counters.long_lines += 1
                continue
            line = fh.readline(MAX_LINE_BYTES + 1)
            if not line:
                at_end = True
                break
            if not line.endswith(b"\n"):
                if len(line) <= MAX_LINE_BYTES:
                    at_end = True
                    break  # 最後一行還沒寫完：下次再讀
                # 超過 4 MB：開始丟棄這一行，只計次數
                budget.bytes_left -= len(line)
                st.offset = fh.tell()
                st.skipping = True
                continue
            budget.bytes_left -= len(line)
            counters.bytes_read += len(line)
            if f.provider == "claude":
                _claude_line(conn, totals, st, line, counters)
            else:
                _codex_line(conn, totals, st, line, counters, f.key)  # 可能丟出 _SwitchToRecord
            del line
            st.offset = fh.tell()
    if at_end:
        st.state.pop("cutoff", None)  # 重算讀完了：之後附加的內容照目前的略過界
    totals.flush(conn, f.key if f.provider == "codex" else None, cutoffs)
    conn.execute(
        "INSERT OR REPLACE INTO scan_state (file_key, inode, device, size, mtime, offset, source, last_total, state, last_seen)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (f.key, f.inode, f.device, size, mtime, st.offset, st.source,
         json.dumps(st.last_total) if st.last_total is not None else None,
         st.state_json(), totals.now))
    return st.offset


def _update_records(conn: sqlite3.Connection) -> None:
    """單日最高與最長連續天數：從 record_days（不套用保留期間）重算後直接寫入。
    record_days 包含所有計入過的日子，所以重算值只會在 Codex 重算扣除時變小，這時紀錄也跟著下修（ADR-0014 LT-18）；
    同樣大時取最早的那天。含快取讀取的單日最高從 record_days_cached 算；連續天數只看主數字。"""
    for provider in (None, *PROVIDERS):
        suffix = f":{provider}" if provider else ""
        where, args = ("WHERE provider = ?", (provider,)) if provider else ("", ())
        cached = conn.execute(f"SELECT day, SUM(tokens) AS t FROM record_days_cached {where}"
                              " GROUP BY day HAVING t > 0 ORDER BY t DESC, day LIMIT 1", args).fetchone()
        _set_record(conn, "best_day_tokens_cached" + suffix, cached)
        days = conn.execute(
            f"SELECT day, SUM(tokens) AS t FROM record_days {where} GROUP BY day HAVING t > 0 ORDER BY day", args).fetchall()
        if not days:
            _set_record(conn, "best_day_tokens" + suffix, None)
            _set_record(conn, "longest_streak_days" + suffix, None)
            continue
        best = min(days, key=lambda r: (-r[1], r[0]))
        _set_record(conn, "best_day_tokens" + suffix, (best[0], best[1]))
        longest, run, prev, end = 0, 0, None, None
        for day, _ in days:
            d = datetime.fromisoformat(day).date()
            run = run + 1 if prev is not None and (d - prev).days == 1 else 1
            prev = d
            if run > longest:
                longest, end = run, day
        _set_record(conn, "longest_streak_days" + suffix, (end, longest))


def _set_record(conn: sqlite3.Connection, key: str, best) -> None:
    """`best` 是 (day, value)；None（全部扣到 0）時刪掉這項紀錄。"""
    if best is None:
        conn.execute("DELETE FROM records WHERE key = ?", (key,))
    else:
        conn.execute("INSERT OR REPLACE INTO records (key, value, day) VALUES (?, ?, ?)", (key, best[1], best[0]))


@dataclass
class ScanResult:
    files: int = 0
    processed: int = 0
    done: bool = False
    progress: int = 0
    counters: Counters = field(default_factory=Counters)


def _scan_row(conn: sqlite3.Connection, file_key: str) -> sqlite3.Row | None:
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM scan_state WHERE file_key = ?", (file_key,)).fetchone()
    finally:
        conn.row_factory = None


def scan(conn: sqlite3.Connection, files: list[LogFile], now: int | None = None,
         budget: Budget | None = None) -> ScanResult:
    now = int(time.time()) if now is None else now
    budget = budget or Budget()
    device_id = history.meta(conn, "device_id") or ""
    days = history.retention_days(conn)
    cutoffs = (history.local_day(now - days * 86400) if days > 0 else "",
               history.local_day(now - min(days or history.HOURLY_TOKENS_DAYS, history.HOURLY_TOKENS_DAYS) * 86400))
    _seen_cutoff(conn)  # 「清除並重新掃描」後刪掉舊的略過界；每個檔案在自己的交易內再讀目前的值
    conn.row_factory = sqlite3.Row
    rows = {r["file_key"]: r for r in conn.execute("SELECT * FROM scan_state")}
    conn.row_factory = None
    result = ScanResult(files=len(files))
    changed = False
    done_bytes = 0
    stale = []
    for index, f in enumerate(files, 1):
        row = rows.get(f.key)
        if row is not None and (row["device"], row["inode"]) == (f.device, f.inode) \
                and row["offset"] == f.size and f.mtime >= row["mtime"]:
            done_bytes += f.size
            if now - row["last_seen"] >= LAST_SEEN_REFRESH or f.mtime != row["mtime"]:
                stale.append((now, f.mtime, f.key))
            continue
        if budget.exhausted():
            done_bytes += min(row["offset"], f.size) if row is not None else 0
            continue
        try:
            for switch in (False, True):
                # 換來源時整個交易回復（這一段已累積、還沒寫入帳本的數字一併丟掉），再從頭重算
                totals, counters = Totals(device_id, now), Counters()
                try:
                    with history._transaction(conn):
                        # 拿到寫入鎖後重新讀這個檔案的進度：上面的整批讀取在交易外，另一個收集器（手動執行、
                        # App 觸發）可能已經處理過同一段，沿用舊 offset 會讓 Codex 的累計差額再加一次
                        row = _scan_row(conn, f.key)
                        # 略過界也一樣：另一個收集器可能已前進 D、刪掉去重列，沿用交易外讀到的舊值會重複計入（審查 C-02）
                        totals.seen_cutoff = history.meta(conn, "seen_cutoff_day")
                        offset = _process(conn, f, row, totals, budget, counters, cutoffs, switch)
                    break
                except _SwitchToRecord:
                    continue
            result.counters.add(counters)
            done_bytes += min(offset, f.size)
            result.processed += 1
            changed = True
        except sqlite3.DatabaseError:
            raise  # 資料庫被鎖住或損毀：其他檔案也寫不進去，整次放棄（不要每個檔案各等 5 秒）
        except Exception as e:
            # 不記錄檔名、路徑或例外訊息（JSONDecodeError 等的訊息會帶出原文）
            result.counters.failed_files += 1
            log(f"Token 統計略過第 {index} 個紀錄檔（{type(e).__name__}）")
    total_bytes = sum(f.size for f in files)
    result.done = not budget.exhausted()
    result.progress = 100 if result.done or total_bytes == 0 else min(99, done_bytes * 100 // total_bytes)
    with history._transaction(conn):
        if stale:
            conn.executemany("UPDATE scan_state SET last_seen = ?, mtime = ? WHERE file_key = ?", stale)
        if changed:
            _update_records(conn)
        c = result.counters
        for key, value in (("token_bad_lines", c.bad_lines), ("token_long_lines", c.long_lines)):
            if value:
                old = int(history.meta(conn, key) or 0)
                conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, str(old + value)))
        suspect = format_suspect(c)
        if suspect is not None:
            # App 讀這個鍵顯示「紀錄格式可能已改變」；證據不足的掃描不改變上次的判斷
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('token_format_suspect', ?)",
                         ("1" if suspect else "0",))
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('token_format_scan', ?)",
                         (json.dumps({"bytes": c.bytes_read, "candidates": c.candidate_lines, "bad": c.bad_lines,
                                      "token_lines": c.token_lines, "at": now}),))
        if history.meta(conn, "first_scan_done") != "1":
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('first_scan_progress', ?)",
                         (str(result.progress),))
            if result.done:
                conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('first_scan_done', '1')")
        _advance_seen_window(conn, now)
    return result


def _seen_cutoff(conn: sqlite3.Connection) -> str | None:
    """這次掃描的略過界。「清除並重新掃描」（首次掃描未完成、去重表與掃描進度都是空的）時刪掉舊的略過界，
    整個歷史重建（舊版 App 的重新掃描不會刪這個鍵）。"""
    cutoff = history.meta(conn, "seen_cutoff_day")
    if cutoff is None or history.meta(conn, "first_scan_done") == "1":
        return cutoff
    if any(conn.execute(f"SELECT 1 FROM {t} LIMIT 1").fetchone() for t in ("scan_state", "seen_ids", "seen_tasks")):
        return cutoff
    with history._transaction(conn):
        conn.execute("DELETE FROM meta WHERE key = 'seen_cutoff_day'")
    return None


def _advance_seen_window(conn: sqlite3.Connection, now: int) -> None:
    """略過界只進不退、每次最多一天（時鐘被設到未來時，錯一次只縮一天，改回後就停）；再刪掉 D − 1 以前的去重列。
    在交易內以資料庫目前的值為準：另一個收集器同時執行、已經前進過時不會被寫回較早的日期（審查 C-02）。"""
    if history.meta(conn, "first_scan_done") != "1":
        return
    target = history.local_day(now - SEEN_DAYS * 86400)
    current = history.meta(conn, "seen_cutoff_day")
    if current is None:
        cutoff = target  # 首次掃描剛完成，或升級前就完成了：一次到位
    else:
        cutoff = max(current, min(target, (date.fromisoformat(current) + timedelta(days=1)).isoformat()))
    if cutoff != current:
        conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('seen_cutoff_day', ?)", (cutoff,))
    prune_before = (date.fromisoformat(cutoff) - timedelta(days=1)).isoformat()
    left = SEEN_PRUNE_ROWS
    for table in SEEN_TABLES:
        if left <= 0:
            break
        left -= conn.execute(f"DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE day < ? LIMIT ?)",
                             (prune_before, left)).rowcount


def run(path: Path | None = None, dirs: Mapping[str, Path] | None = None, now: int | None = None,
        budget: Budget | None = None) -> ScanResult:
    path = path or history.HISTORY_PATH
    files = list_files(dirs or log_dirs())
    with history._private_files():
        history._tighten_permissions(path)
        conn = history.connect(path)
        try:
            first = history.meta(conn, "first_scan_done") != "1"
            result = scan(conn, files, now, budget)
        finally:
            conn.close()
    history._tighten_permissions(path)
    if first and result.files:
        log(f"Token 統計：首次整理 {result.progress}%（{result.files} 個紀錄檔）")
    return result


def run_safely(path: Path | None = None) -> bool:
    """`run` 的外層：不丟出任何例外（Token 統計失敗不影響收集器的結束碼）。"""
    try:
        try:
            system.lower_priority()  # 首次掃描可能讀數百 MB：降低優先順序
        except OSError:
            pass
        run(path)
        return True
    except history.HistoryError as e:
        log(f"略過 Token 統計：{e}")
    except sqlite3.DatabaseError as e:
        log(f"略過 Token 統計（{type(e).__name__}）：history.sqlite3 被鎖住或已損毀")
    except Exception as e:
        log(f"略過 Token 統計：{type(e).__name__}")
    return False
