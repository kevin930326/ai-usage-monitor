"""第二層：上傳這台電腦的每日 Token 加總、下載其他電腦的（ADR-0011 第 2 節、FR-49）。

- 只有安裝第二層的電腦才執行：config.json 的 `token_sync` 為 true（set-tier2.sh／set-tier2.ps1 寫入）、
  有 https 的 `relay_url`，且有這台電腦的寫入密鑰（credentials.DEVICE_KEY）。Mac 單機使用者永遠不上傳。
- 只上傳 `daily_tokens` 裡本機 device_id 的列，而且只有「上次成功上傳後有變動」的列（含昨天：跨日晚到的紀錄）。
  欄位只有日期、服務、模型名稱、四種 Token 與推理、任務秒數、最長任務；不含任務次數、每小時資料、路徑、
  session／訊息 ID、檔名。
- 每小時一次＋本機日期改變後的第一次執行；每批最多 400 列。失敗時不前進，以 5 分鐘、15 分鐘、1 小時、6 小時
  遞增間隔重試；連續兩次 401 停止上傳（meta.upload_status = revoked，不刪除本機資料），重新執行設定腳本才恢復。
- 有讀取密鑰（Mac）時下載所有裝置的每日加總：這台電腦在中繼上的 device_id（中繼依密鑰決定，和本機
  meta.device_id 不同）一律略過，本機的數字以本機統計為準；其他裝置的列整批取代寫進本機 daily_tokens。
  上傳只選本機 device_id 的列，所以下載到的列永遠不會再上傳。
- 換電腦（ADR-0014 D-2）：第一次上傳時把這台電腦的硬體指紋（`machine.fingerprint`，只存雜湊）記在
  `meta.machine_fingerprint`。之後指紋不同＝資料庫連同密鑰從別台電腦搬來：暫停上傳（`upload_status = copied`，
  兩台用同一個身分會互相覆蓋），App 提示照 docs/runbook.md 處理；重新執行設定腳本（`reset`）時改記這台的指紋。
  下載照常。讀不到指紋時不檢查。
- 日誌只記錄狀態碼與錯誤類別，不記錄密鑰、網址與資料內容；狀態沒變時不重複記錄。任何失敗都不影響收集器的
  其他工作與結束碼。
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import sys
import time
from collections.abc import Iterable
from pathlib import Path

from . import credentials, history, machine, token_stats
from .http import HTTPStatusError, request_json
from .log import log
from .models import ProviderError, parse_iso
from .paths import CONFIG_PATH

UPLOAD_INTERVAL = 3600
DOWNLOAD_INTERVAL = 3600
BATCH_ROWS = 400
MAX_BATCHES = 5  # 一次執行最多 2,000 列；首次上傳一年的資料分幾輪（每 5 分鐘一輪）
TIME_BUDGET = 60  # 秒：一次執行花在上傳的時間上限（排程的執行時間上限是 4 分鐘）
BACKOFF = (300, 900, 3600, 21600)
REVOKE_AFTER = 2  # 連續幾次 401 視為密鑰失效（一次可能是中繼暫時設定錯誤）。中繼自己不回 403：
# 403 來自 Cloudflare 邊緣（WAF、Bot Fight Mode 等），照一般失敗退避重試，不當成密鑰失效
SYNC_DAYS = 399  # 中繼只收 400 天內（UTC）的日期；本機日期與 UTC 最多差一天
MAX_VALUE = 10**12
NAME_MAX = 32
FIELDS = ("input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens", "reasoning_tokens",
          "task_seconds", "longest_task_seconds")
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_DEVICE_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f  ]")


def load_config(path: Path | None = None) -> tuple[bool, str | None]:
    """（是否安裝第二層, 中繼網址）。網址不是 https 時當成沒有設定（密鑰不能以明文傳送）。"""
    try:
        config = json.loads((path or CONFIG_PATH).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
        return False, None
    if not isinstance(config, dict) or config.get("token_sync") is not True:
        return False, None
    url = config.get("relay_url")
    if not isinstance(url, str) or not url.startswith("https://"):
        return True, None
    return True, url.rstrip("/")


# MARK: - meta

def _meta_int(conn: sqlite3.Connection, key: str) -> int:
    try:
        return int(history.meta(conn, key) or 0)
    except ValueError:
        return 0


def _set_meta(conn: sqlite3.Connection, **values: object) -> None:
    conn.executemany("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                     [(k, str(v)) for k, v in values.items()])


def _own_ids(conn: sqlite3.Connection) -> set[str]:
    """這台電腦在中繼上用過的所有 device_id（重新註冊後舊的那個也是自己的資料，下載時要略過）"""
    try:
        ids = json.loads(history.meta(conn, "relay_device_ids") or "[]")
    except ValueError:
        ids = []
    own = {i for i in ids if isinstance(i, str)} if isinstance(ids, list) else set()
    current = history.meta(conn, "relay_device_id")
    return own | {current} if current else own


def _report(conn: sqlite3.Connection, kind: str, status: str, message: str | None = None) -> None:
    """記下 upload_status／sync_status；狀態改變時才寫日誌（每 5 分鐘一輪，不重複記錄同一件事）。"""
    key = f"{kind}_status"
    if history.meta(conn, key) != status and message:
        log(message)
    _set_meta(conn, **{key: status})


def _failed(conn: sqlite3.Connection, kind: str, now: int, message: str) -> None:
    failures = _meta_int(conn, f"{kind}_failures") + 1
    _set_meta(conn, **{f"{kind}_failures": failures,
                       f"{kind}_next_at": now + BACKOFF[min(failures, len(BACKOFF)) - 1]})
    _report(conn, kind, "error", message)


def _describe(e: Exception) -> str:
    if isinstance(e, HTTPStatusError):
        # 401 以外帶上原因（http._reason：中繼固定的驗證訊息；403 沒有時是「可能被 Cloudflare 擋下」），不含資料
        return f"HTTP {e.status}" if e.status == 401 else str(e)
    if isinstance(e, ProviderError):
        return str(e)  # http.py 與這裡的固定訊息（網路錯誤、憑證、狀態碼），不含網址、密鑰與內容
    return type(e).__name__


# MARK: - 上傳

def _row_hash(values: Iterable[object]) -> str:
    return hashlib.sha256("|".join(map(str, values)).encode()).hexdigest()[:32]


def _valid_key(provider: str, model: str) -> bool:
    return provider in token_stats.PROVIDERS and (model == "other" or token_stats.normalize_model(model) == model)


def _until(now: int) -> str:
    """中繼收的最晚日期：明天（UTC）。本機時鐘曾經設錯時紀錄裡會有未來的日期，那些列不送（整批會被拒絕）。"""
    return time.strftime("%Y-%m-%d", time.gmtime(now + 86400))


def pending_rows(conn: sqlite3.Connection, since: str,
                 until: str = "9999-12-31") -> list[tuple[tuple[str, str, str], tuple[int, ...], str]]:
    """本機 device_id、`since`～`until`、和上次成功上傳時不同的列：[(（day, provider, model）, 數值, 雜湊)]。
    中繼會拒絕的列（日期超出範圍、數值超過上限）不列入：一列被拒整批都會被拒，其他的列就永遠傳不上去。"""
    device_id = history.meta(conn, "device_id") or ""
    uploaded = {(d, p, m): h for d, p, m, h in conn.execute("SELECT day, provider, model, hash FROM upload_state")}
    result = []
    for row in conn.execute(f"SELECT day, provider, model, {', '.join(FIELDS)} FROM daily_tokens"
                            " WHERE device_id = ? AND day >= ? AND day <= ? ORDER BY day, provider, model",
                            (device_id, since, until)):
        key, values = (row[0], row[1], row[2]), tuple(int(v) for v in row[3:])
        digest = _row_hash(row)
        if uploaded.get(key) != digest and _valid_key(key[1], key[2]) and all(0 <= v <= MAX_VALUE for v in values):
            result.append((key, values, digest))
    return result


def _mark_uploaded(conn: sqlite3.Connection, batch, now: int) -> None:
    conn.executemany("INSERT OR REPLACE INTO upload_state (day, provider, model, hash, uploaded_at) VALUES (?, ?, ?, ?, ?)",
                     [(*key, digest, now) for key, _, digest in batch])


def _adopt_device_id(conn: sqlite3.Connection, relay_id: str) -> bool:
    """記下中繼回報的 device_id。換了（重新註冊成另一台裝置）時，舊的留在「自己的」清單（下載時略過），
    並清掉上傳進度讓所有列重新上傳到新的 device_id。回傳是否換了。"""
    known = history.meta(conn, "relay_device_id")
    if known == relay_id:
        return False
    own = sorted(_own_ids(conn) | {relay_id})
    _set_meta(conn, relay_device_id=relay_id, relay_device_ids=json.dumps(own))
    if known:
        conn.execute("DELETE FROM upload_state")
    return known is not None


def upload(conn: sqlite3.Connection, url: str, key: str, now: int) -> bool:
    """上傳有變動的列；回傳是否還有沒傳完的列（下一輪接著傳）。失敗時丟出例外，已成功的批次保留進度。"""
    since, until = history.local_day(now - SYNC_DAYS * 86400), _until(now)
    pending = pending_rows(conn, since, until)
    if not pending and history.meta(conn, "relay_device_id"):
        return False
    started = time.monotonic()
    for _ in range(MAX_BATCHES):
        batch = pending[:BATCH_ROWS]
        rows = [{"day": k[0], "provider": k[1], "model": k[2], **dict(zip(FIELDS, values))} for k, values, _ in batch]
        response = request_json(f"{url}/tokens/daily", {"Authorization": f"Bearer {key}"}, body={"rows": rows})
        relay_id = response.get("device_id") if isinstance(response, dict) else None
        if not isinstance(relay_id, str) or not _DEVICE_RE.match(relay_id) or response.get("accepted") != len(rows):
            raise ProviderError("回應格式不對")
        with history._transaction(conn):
            changed = _adopt_device_id(conn, relay_id)
            _mark_uploaded(conn, batch, now)
        pending = pending_rows(conn, since, until) if changed else pending[len(batch):]
        if not pending:
            return False
        if time.monotonic() - started > TIME_BUDGET:
            break
    return True


# MARK: - 下載

def _clean_name(value: object) -> str:
    if isinstance(value, str):
        name = value.strip()
        if name and len(name) <= NAME_MAX and not _CONTROL_RE.search(name):
            return name
    return "未命名的裝置"


def _timestamp(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return int(parse_iso(value).timestamp())
    except ValueError:
        return None


def _remote_row(r: object, skip: set[str], since: str) -> tuple | None:
    """中繼下載的一列 → 寫進本機 daily_tokens 的值；格式不對、是自己的或太舊的列回傳 None。"""
    if not isinstance(r, dict):
        return None
    device_id, day, provider, model = r.get("device_id"), r.get("day"), r.get("provider"), r.get("model")
    if not (isinstance(device_id, str) and _DEVICE_RE.match(device_id) and device_id not in skip):
        return None
    if not (isinstance(day, str) and _DAY_RE.match(day) and day >= since and isinstance(provider, str)
            and isinstance(model, str) and _valid_key(provider, model)):
        return None
    values = []
    for field in FIELDS:
        v = r.get(field, 0)
        if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= MAX_VALUE:
            return None
        values.append(v)
    return (device_id, day, provider, model, *values)


def download(conn: sqlite3.Connection, url: str, read_key: str, now: int) -> int:
    """下載其他裝置的每日加總，整批取代本機的其他裝置列與裝置清單；回傳寫入的列數。
    只保存本機保留期間內的日期（FR-37、ADR-0009 第 5 節）：已過期的不會因為下載而回來。"""
    since = history.local_day(now - SYNC_DAYS * 86400)
    days = history.retention_days(conn)
    oldest = history.local_day(now - days * 86400) if days > 0 else None
    if oldest is not None and oldest > since:
        since = oldest
    response = request_json(f"{url}/tokens/daily?from={since}", {"Authorization": f"Bearer {read_key}"})
    if not isinstance(response, dict) or not isinstance(response.get("rows"), list) \
            or not isinstance(response.get("devices"), list):
        raise ProviderError("回應格式不對")
    own = _own_ids(conn)
    local_id = history.meta(conn, "device_id") or ""
    rows = [v for v in (_remote_row(r, own | {local_id}, since) for r in response["rows"]) if v]
    devices = []
    deleted = []
    for d in response["devices"]:
        # 撤銷時一併刪除了資料（中繼回 has_data: false）：不再列出、不算台數，本機的舊資料不論日期一併刪除
        # （截斷的下載不會刪掉較舊的日子）。舊版中繼沒有這個欄位時照常列出
        if isinstance(d, dict) and d.get("revoked") is True and d.get("has_data") is False:
            if isinstance(d.get("device_id"), str) and d["device_id"] not in own | {local_id}:
                deleted.append((d["device_id"],))
            continue
        if isinstance(d, dict) and isinstance(d.get("device_id"), str) and _DEVICE_RE.match(d["device_id"]):
            devices.append((d["device_id"], _clean_name(d.get("name")), _timestamp(d.get("last_upload_at")),
                            1 if d.get("revoked") is True else 0, 1 if d["device_id"] in own else 0))
    # 中繼超過下載上限時只回最新的日子（truncated）：最舊的那天可能不完整、更早的沒有回傳，
    # 只取代比最舊那天更新的日子，其餘保留上次的數字（不倒退）
    truncated = response.get("truncated") is True
    delete = ("DELETE FROM daily_tokens WHERE device_id != ? AND day >= ?", (local_id, since))
    if truncated:
        returned = [r["day"] for r in response["rows"]
                    if isinstance(r, dict) and isinstance(r.get("day"), str) and _DAY_RE.match(r["day"])]
        delete = ("DELETE FROM daily_tokens WHERE device_id != ? AND day > ?", (local_id, min(returned or ["9999"])))
        if history.meta(conn, "sync_truncated") != "1":
            log("第二層下載超過中繼的列數上限，只更新最近的日子（較早的日子保留上次的數字）")
    with history._transaction(conn):
        _set_meta(conn, sync_truncated=1 if truncated else 0)
        conn.execute(*delete)
        conn.executemany("DELETE FROM daily_tokens WHERE device_id = ?", deleted)
        if oldest is not None:
            conn.execute("DELETE FROM daily_tokens WHERE device_id != ? AND day < ?", (local_id, oldest))
        conn.executemany(f"""INSERT OR REPLACE INTO daily_tokens
            (device_id, day, provider, model, {', '.join(FIELDS)}, task_count, updated_at)
            VALUES (?, ?, ?, ?, {', '.join('?' * len(FIELDS))}, 0, ?)""", [(*r, now) for r in rows])
        conn.execute("DELETE FROM devices")
        conn.executemany("INSERT OR REPLACE INTO devices (device_id, name, last_upload_at, revoked, is_self)"
                         " VALUES (?, ?, ?, ?, ?)", devices)
    return len(rows)


# MARK: - 每輪執行

def _due(conn: sqlite3.Connection, kind: str, interval: int, now: int) -> bool:
    next_at = _meta_int(conn, f"{kind}_next_at")
    if now < next_at <= now + BACKOFF[-1]:
        return False  # 失敗後的退避期間（比最長的退避還遠：時鐘曾被設到未來時寫下的，視為已到期，ADR-0014 LT-11）
    return (now - _meta_int(conn, f"{kind}_last_success") >= interval
            or history.meta(conn, f"{kind}_last_day") != history.local_day(now)
            or history.meta(conn, f"{kind}_more") == "1")


def _same_machine(conn: sqlite3.Connection) -> bool:
    """資料庫是不是在這台電腦建立（或已在這台重新設定過）的；第一次檢查時記下這台的指紋。"""
    current = machine.fingerprint()
    if current is None:
        return True
    stored = history.meta(conn, "machine_fingerprint")
    if stored is None:
        _set_meta(conn, machine_fingerprint=current)
        return True
    if stored == current:
        return True
    _report(conn, "upload", "copied", "第二層上傳暫停：history.sqlite3 是從另一台電腦搬來的，兩台用同一個身分上傳會互相覆蓋；"
            "照 docs/runbook.md「換電腦」處理，重新執行第二層的設定後恢復")
    return False


def _sync_upload(conn: sqlite3.Connection, url: str, now: int) -> None:
    if history.meta(conn, "upload_status") == "revoked" or not _due(conn, "upload", UPLOAD_INTERVAL, now):
        return
    if not _same_machine(conn):
        return
    key = credentials.read(credentials.DEVICE_KEY)
    if not key:
        _report(conn, "upload", "no_key", "略過第二層上傳：找不到這台電腦的寫入密鑰，重新執行第二層的設定（docs/tier2-setup.md）")
        return
    try:
        more = upload(conn, url, key, now)
    except HTTPStatusError as e:
        if e.status == 401:
            auth = _meta_int(conn, "upload_auth_failures") + 1
            _set_meta(conn, upload_auth_failures=auth)
            if auth >= REVOKE_AFTER:
                _report(conn, "upload", "revoked", f"第二層上傳停止：寫入密鑰已失效（HTTP {e.status}），"
                        "本機資料保留；換新密鑰後重新執行第二層的設定")
                return
        _failed(conn, "upload", now, f"第二層上傳失敗（{_describe(e)}），稍後重試")
        return
    except ProviderError as e:
        _failed(conn, "upload", now, f"第二層上傳失敗（{_describe(e)}），稍後重試")
        return
    _set_meta(conn, upload_failures=0, upload_next_at=0, upload_auth_failures=0, upload_last_success=now,
              upload_last_day=history.local_day(now), upload_more=1 if more else 0)
    _report(conn, "upload", "ok", None)


def _sync_download(conn: sqlite3.Connection, url: str, now: int) -> None:
    # 還不知道自己在中繼上的 device_id 時不下載：分不出哪些列是自己的，會重複計算
    if not history.meta(conn, "relay_device_id") or not _due(conn, "sync", DOWNLOAD_INTERVAL, now):
        return
    read_key = credentials.read(credentials.READ_KEY)
    if not read_key:
        return  # Windows 與沒有設定讀取密鑰的 Mac：只上傳
    try:
        download(conn, url, read_key, now)
    except (ProviderError, sqlite3.DatabaseError) as e:
        _failed(conn, "sync", now, f"第二層下載失敗（{_describe(e)}），稍後重試")
        return
    _set_meta(conn, sync_failures=0, sync_next_at=0, sync_last_success=now, sync_last_day=history.local_day(now))
    _report(conn, "sync", "ok", None)


def run(path: Path | None = None, now: int | None = None, config_path: Path | None = None) -> None:
    enabled, url = load_config(config_path)
    if not enabled:
        return
    path = path or history.HISTORY_PATH
    now = int(time.time()) if now is None else now
    with history._private_files():
        history._tighten_permissions(path)
        conn = history.connect(path)
        try:
            if url is None:
                _report(conn, "upload", "not_configured", "略過第二層上傳：config.json 沒有 https:// 的 relay_url")
                return
            _sync_upload(conn, url, now)
            _sync_download(conn, url, now)
        finally:
            conn.close()


def run_safely(path: Path | None = None) -> None:
    """`run` 的外層：不丟出任何例外，日誌只記錄類別（第二層失敗不影響 Token 統計與額度）。"""
    try:
        run(path)
    except history.HistoryError as e:
        log(f"略過第二層同步：{e}")
    except Exception as e:
        log(f"略過第二層同步：{type(e).__name__}")


def reset(path: Path | None = None) -> None:
    """設定腳本換新密鑰後呼叫：清除失敗、「密鑰失效」與「從別台搬來」的狀態，下一輪立即上傳（保留上傳進度）。
    在這台電腦執行，所以改記這台的硬體指紋（ADR-0014 D-2）。"""
    path = path or history.HISTORY_PATH
    with history._private_files():
        conn = history.connect(path)
        try:
            with history._transaction(conn):
                conn.execute("DELETE FROM meta WHERE key IN ('upload_status', 'upload_failures', 'upload_next_at',"
                             " 'upload_auth_failures', 'upload_last_success', 'sync_status', 'sync_failures',"
                             " 'sync_next_at', 'sync_last_success', 'machine_fingerprint')")
                current = machine.fingerprint()
                if current is not None:
                    _set_meta(conn, machine_fingerprint=current)
        finally:
            conn.close()
        history._tighten_permissions(path)


def forget(path: Path | None = None) -> None:
    """關閉第二層時呼叫：刪除本機的其他裝置列與裝置清單（面板回到「這台 Mac」）；本機的統計與上傳進度保留。"""
    path = path or history.HISTORY_PATH
    if not path.exists():
        return
    with history._private_files():
        conn = history.connect(path)
        try:
            with history._transaction(conn):
                conn.execute("DELETE FROM daily_tokens WHERE device_id != ?", (history.meta(conn, "device_id") or "",))
                conn.execute("DELETE FROM devices")
        finally:
            conn.close()
        history._tighten_permissions(path)


def status(path: Path | None = None) -> dict:
    """`python -m usage_collector.token_sync status`：上傳狀態（不含密鑰與資料內容）。
    還沒有資料庫時不建立（收集器第一次執行時才以 0600 建立）。"""
    path = path or history.HISTORY_PATH
    if not path.exists():
        return {"history": "尚未建立（收集器還沒執行過）"}
    conn = history.connect(path)
    try:
        keys = ("upload_status", "upload_last_success", "upload_failures", "upload_more", "relay_device_id",
                "sync_status", "sync_last_success")
        result: dict = {k: history.meta(conn, k) for k in keys}
        now = int(time.time())
        result["pending_rows"] = len(pending_rows(conn, history.local_day(now - SYNC_DAYS * 86400), _until(now)))
        result["devices"] = conn.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
        return result
    finally:
        conn.close()


def main(argv: list[str]) -> int:
    if argv == ["reset"]:
        reset()
        print("已重設第二層的上傳狀態，下一輪（5 分鐘內）會上傳")
        return 0
    if argv == ["forget"]:
        forget()
        print("已刪除本機的其他電腦資料（中繼上的資料不動）")
        return 0
    if argv == ["status"]:
        print(json.dumps(status(), ensure_ascii=False, indent=2))
        return 0
    print("用法：python -m usage_collector.token_sync reset|forget|status", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
