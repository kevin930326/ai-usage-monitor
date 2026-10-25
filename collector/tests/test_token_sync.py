"""第二層的上傳與下載（ADR-0011 第 2 節、FR-49）。不連網：假的中繼照真的中繼的規則運作
（device_id 由密鑰決定、以（裝置、日期、服務、模型）覆蓋寫入），密鑰以 mock 取代 Keychain／認證管理員。"""
import io
import json
import sqlite3
import sys
import tempfile
import time
import unittest
import uuid
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from usage_collector import __main__ as cli
from usage_collector import credentials, history, token_sync
from usage_collector.http import HTTPStatusError
from usage_collector.models import ProviderError

NOW = 1_792_000_000  # 2026-10-15 前後
HOUR = 3600
DAY = 86400
URL = "https://relay.example.dev"
READ = "read-secret"
FIELDS = token_sync.FIELDS


class FakeRelay:
    """照 relay/src/tokens.ts 的規則：密鑰 → device_id、覆蓋寫入、讀取密鑰下載全部。"""

    def __init__(self):
        self.keys: dict[str, str] = {}
        self.names: dict[str, str] = {}
        self.rows: dict[tuple, dict] = {}
        self.calls: list[tuple[str, dict | None]] = []
        self.tokens: list[str] = []
        self.fail: list[Exception] = []
        self.apply_then_fail = False
        self.now: int | None = None
        self.revoked: set[str] = set()
        self.has_data_field = True  # False：舊版中繼，下載的裝置清單沒有 has_data

    def add(self, key: str, name: str) -> str:
        device_id = str(uuid.uuid4())
        self.keys[key] = device_id
        self.names[device_id] = name
        return device_id

    def uploads(self, key: str | None = None) -> list[list[dict]]:
        return [body["rows"] for (url, body), token in zip(self.calls, self.tokens)
                if body is not None and (key is None or token == key)]

    def __call__(self, url, headers, body=None, timeout=15):
        token = headers["Authorization"].removeprefix("Bearer ")
        self.calls.append((url, body))
        self.tokens.append(token)
        if self.fail:
            raise self.fail.pop(0)
        if body is not None:
            device_id = self.keys.get(token)
            if device_id is None:
                raise HTTPStatusError("驗證失敗 (HTTP 401)，請重新登入", 401)
            # 中繼的 dayInRange 與數值上限：一列不合整批 422
            latest = time.strftime("%Y-%m-%d", time.gmtime(self.now + DAY)) if self.now else "9999-12-31"
            if any(r["day"] > latest or any(r[f] > token_sync.MAX_VALUE for f in FIELDS) for r in body["rows"]):
                raise HTTPStatusError("HTTP 422：day 必須是 400 天內到明天的日期", 422)
            for r in body["rows"]:
                self.rows[(device_id, r["day"], r["provider"], r["model"])] = {f: r[f] for f in FIELDS}
            if self.apply_then_fail:  # 中繼寫入了，但回應在路上斷掉
                self.apply_then_fail = False
                raise ProviderError("網路錯誤（連線逾時或中斷）")
            return {"device_id": device_id, "accepted": len(body["rows"])}
        if token != READ:
            raise HTTPStatusError("驗證失敗 (HTTP 401)，請重新登入", 401)
        devices = [{"device_id": d, "name": n, "revoked": d in self.revoked, "last_upload_at": "2026-10-15T00:00:00Z"}
                   for d, n in self.names.items()]
        if self.has_data_field:
            for d in devices:
                d["has_data"] = any(k[0] == d["device_id"] for k in self.rows)
        return {
            "devices": devices,
            "rows": [{"device_id": k[0], "day": k[1], "provider": k[2], "model": k[3], **v} for k, v in self.rows.items()],
        }

    def total(self, device_id: str | None = None) -> int:
        return sum(v["input_tokens"] for k, v in self.rows.items() if device_id is None or k[0] == device_id)


class Machine:
    """一台裝了收集器的電腦：自己的 history.sqlite3、config.json 與密鑰。"""

    def __init__(self, root: Path, name: str, relay: FakeRelay, read_key: str | None = None,
                 enabled: bool = True, url: str = URL):
        self.dir = root / name
        self.dir.mkdir()
        self.path = self.dir / "history.sqlite3"
        self.config = self.dir / "config.json"
        self.config.write_text(json.dumps({"relay_url": url, "token_sync": enabled}), encoding="utf-8")
        self.relay = relay
        self.key = f"aumd_{name}"
        self.relay_id = relay.add(self.key, name)
        self.secrets = {credentials.DEVICE_KEY: self.key, credentials.READ_KEY: read_key}
        conn = history.connect(self.path)
        self.device_id = history.meta(conn, "device_id")
        conn.close()
        self.log = io.StringIO()

    def set_tokens(self, day_offset: int, value: int, now: int = NOW, provider: str = "claude",
                   model: str = "claude-opus-5-5"):
        """本機統計寫入（token_stats 只寫本機 device_id 的列）"""
        day = history.local_day(now + day_offset * DAY)
        with sqlite3.connect(self.path) as conn:
            conn.execute(f"""INSERT OR REPLACE INTO daily_tokens (device_id, day, provider, model, {', '.join(FIELDS)},
                             task_count, updated_at) VALUES (?, ?, ?, ?, ?, 2, 3, 4, 1, 60, 30, 9, ?)""",
                         (self.device_id, day, provider, model, value, now))
        conn.close()

    def run(self, now: int):
        self.relay.now = now
        with mock.patch.object(token_sync, "request_json", self.relay), \
                mock.patch.object(token_sync.credentials, "read", side_effect=lambda n: self.secrets.get(n)), \
                redirect_stderr(self.log):
            token_sync.run(self.path, now=now, config_path=self.config)

    def query(self, sql: str, args=()):
        with sqlite3.connect(self.path) as conn:
            rows = conn.execute(sql, args).fetchall()
        conn.close()
        return rows

    def meta(self, key: str):
        rows = self.query("SELECT value FROM meta WHERE key = ?", (key,))
        return rows[0][0] if rows else None

    def local_total(self) -> int:
        return self.query("SELECT COALESCE(SUM(input_tokens), 0) FROM daily_tokens WHERE device_id = ?", (self.device_id,))[0][0]

    def total_by_device(self) -> dict[str, int]:
        return dict(self.query("SELECT device_id, SUM(input_tokens) FROM daily_tokens GROUP BY device_id"))


class TokenSyncTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.relay = FakeRelay()

    def tearDown(self):
        self.tmp.cleanup()

    def machine(self, name="mac", **kwargs) -> Machine:
        return Machine(self.root, name, self.relay, **kwargs)


class EnabledTest(TokenSyncTestCase):
    def test_not_installed_never_uploads(self):
        mac = self.machine(enabled=False)
        mac.set_tokens(0, 100)
        mac.run(NOW)
        self.assertEqual(self.relay.calls, [])
        self.assertIsNone(mac.meta("upload_status"))

    def test_missing_config_does_not_touch_the_database(self):
        path = self.root / "none" / "history.sqlite3"
        token_sync.run(path, now=NOW, config_path=self.root / "missing.json")
        self.assertFalse(path.exists())

    def test_http_url_is_refused_and_logged_once(self):
        mac = self.machine(url="http://relay.example.dev")
        mac.set_tokens(0, 100)
        mac.run(NOW)
        mac.run(NOW + 300)
        self.assertEqual(self.relay.calls, [])
        self.assertEqual(mac.meta("upload_status"), "not_configured")
        self.assertEqual(mac.log.getvalue().count("relay_url"), 1)

    def test_missing_key_skips_without_requests(self):
        mac = self.machine()
        mac.secrets[credentials.DEVICE_KEY] = None
        mac.set_tokens(0, 100)
        mac.run(NOW)
        self.assertEqual(self.relay.calls, [])
        self.assertEqual(mac.meta("upload_status"), "no_key")


class UploadTest(TokenSyncTestCase):
    def test_first_run_uploads_only_whitelisted_fields_of_local_rows(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        mac.set_tokens(-1, 50, provider="codex", model="gpt-6.1-sol")
        mac.run(NOW)
        (rows,) = self.relay.uploads()
        self.assertEqual(len(rows), 2)
        for r in rows:
            self.assertEqual(set(r), {"day", "provider", "model", *FIELDS})  # 沒有 task_count、device_id、updated_at
        self.assertEqual(mac.meta("relay_device_id"), mac.relay_id)
        self.assertEqual(mac.meta("upload_status"), "ok")
        self.assertEqual(self.relay.total(mac.relay_id), 150)

    def test_only_changed_rows_hourly_or_after_the_date_changes(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        mac.set_tokens(-1, 50)
        mac.run(NOW)
        mac.set_tokens(0, 120, now=NOW)
        mac.run(NOW + 300)  # 一小時內：不上傳
        self.assertEqual(len(self.relay.uploads()), 1)
        mac.run(NOW + HOUR)
        self.assertEqual([len(b) for b in self.relay.uploads()], [2, 1])
        self.assertEqual(self.relay.uploads()[-1][0]["input_tokens"], 120)
        mac.run(NOW + 2 * HOUR)  # 沒有變動：不連線
        self.assertEqual(len(self.relay.calls), 2)

    def test_date_change_uploads_before_the_hour(self):
        mac = self.machine()
        midnight = NOW - NOW % DAY + DAY  # 不在意時區：只要 local_day 改變
        start = midnight - 600
        while history.local_day(start) == history.local_day(start + 900):
            start += 600
        mac.set_tokens(0, 100, now=start)
        mac.run(start)
        mac.set_tokens(0, 130, now=start)
        mac.run(start + 900)
        self.assertEqual(len(self.relay.uploads()), 2)

    def test_batches_of_400_and_continue_next_run(self):
        mac = self.machine()
        for i in range(2100):
            mac.set_tokens(-(i % 300), 1, model=f"claude-m{i // 300}")
        mac.run(NOW)
        self.assertEqual([len(b) for b in self.relay.uploads()], [400] * 5)
        self.assertEqual(mac.meta("upload_more"), "1")
        mac.run(NOW + 300)  # 還有沒傳完的：下一輪接著傳，不等一小時
        self.assertEqual([len(b) for b in self.relay.uploads()][-1], 100)
        self.assertEqual(len(self.relay.rows), 2100)
        self.assertEqual(mac.meta("upload_more"), "0")

    def test_rows_older_than_the_relay_accepts_are_not_sent(self):
        mac = self.machine()
        mac.set_tokens(-450, 7)
        mac.set_tokens(0, 1)
        mac.run(NOW)
        self.assertEqual([r["input_tokens"] for r in self.relay.uploads()[0]], [1])

    def test_rows_the_relay_would_reject_do_not_block_the_others(self):
        # 本機時鐘曾經設錯：紀錄裡有未來的日期。一列被拒整批都會被拒，今天的列就永遠傳不上去
        mac = self.machine()
        mac.set_tokens(0, 100)
        mac.set_tokens(30, 5)
        mac.set_tokens(-1, token_sync.MAX_VALUE + 1)
        mac.run(NOW)
        self.assertEqual(mac.meta("upload_status"), "ok")
        self.assertEqual(self.relay.total(mac.relay_id), 100)
        self.assertEqual(mac.meta("relay_device_id"), mac.relay_id)

    def test_rejected_upload_logs_the_relay_reason(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        self.relay.fail = [HTTPStatusError("HTTP 422：provider 只能是 claude 或 codex", 422)]
        mac.run(NOW)
        self.assertIn("HTTP 422：provider 只能是 claude 或 codex", mac.log.getvalue())


class FailureTest(TokenSyncTestCase):
    def test_failure_backs_off_and_does_not_advance(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        self.relay.fail = [ProviderError("網路錯誤")] * 5
        times = [NOW, NOW + 300, NOW + 300 + 900, NOW + 1200 + 3600, NOW + 4800 + 21600]
        for t in times:
            mac.run(t)
            mac.run(t + 60)  # 退避期間不連線
        self.assertEqual(len(self.relay.calls), 5)
        self.assertEqual(mac.meta("upload_next_at"), str(times[-1] + 21600))
        self.assertEqual(mac.query("SELECT COUNT(*) FROM upload_state")[0][0], 0)
        mac.run(times[-1] + 21600)
        self.assertEqual(self.relay.total(mac.relay_id), 100)
        self.assertEqual(mac.meta("upload_failures"), "0")
        self.assertEqual(mac.log.getvalue().count("第二層上傳失敗"), 1)  # 狀態沒變時不重複記錄
        self.assertIn("第二層上傳失敗（網路錯誤）", mac.log.getvalue())  # 失敗的種類要看得出來

    def test_failure_kind_is_logged(self):
        # 不能都寫成同一句「網路錯誤或回應格式不對」：Windows 上分不出是憑證、標頭還是 Cloudflare
        for error in (ProviderError("網路錯誤（HTTPS 憑證驗證失敗）"), ProviderError("請求標頭含有無效字元，密鑰可能貼錯"),
                      ProviderError("回應不是 JSON（HTTP 200），可能被 Cloudflare 擋下或 API 已變更")):
            mac = self.machine(f"mac-{len(self.relay.calls)}")
            mac.set_tokens(0, 100)
            self.relay.fail = [error]
            mac.run(NOW)
            self.assertIn(f"第二層上傳失敗（{error}）", mac.log.getvalue())

    def test_two_consecutive_401_stop_until_reset(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        self.relay.keys.pop(mac.key)  # 撤銷
        mac.run(NOW)
        self.assertEqual(mac.meta("upload_status"), "error")
        mac.run(NOW + 300)
        self.assertEqual(mac.meta("upload_status"), "revoked")
        calls = len(self.relay.calls)
        mac.run(NOW + DAY)
        self.assertEqual(len(self.relay.calls), calls)  # 停止上傳
        self.assertEqual(mac.local_total(), 100)  # 不刪除本機資料
        self.assertIn("寫入密鑰已失效", mac.log.getvalue())
        # 換新密鑰、重新執行設定
        mac.key = mac.secrets[credentials.DEVICE_KEY] = "aumd_new"
        self.relay.keys["aumd_new"] = mac.relay_id
        with mock.patch.object(history, "HISTORY_PATH", mac.path):
            token_sync.reset()
        mac.run(NOW + DAY + 60)
        self.assertEqual(mac.meta("upload_status"), "ok")
        self.assertEqual(self.relay.total(mac.relay_id), 100)

    def test_a_single_401_between_successes_does_not_revoke(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        self.relay.fail = [HTTPStatusError("驗證失敗 (HTTP 401)", 401)]
        mac.run(NOW)
        mac.run(NOW + 300)
        self.assertEqual(mac.meta("upload_status"), "ok")
        self.assertEqual(mac.meta("upload_auth_failures"), "0")

    def test_403_from_the_edge_backs_off_without_revoking(self):
        # 中繼自己不回 403：Cloudflare 邊緣的拒絕（WAF、Bot Fight Mode）可能持續好幾輪，不是密鑰失效
        mac = self.machine()
        mac.set_tokens(0, 100)
        self.relay.fail = [HTTPStatusError("HTTP 403（可能被 Cloudflare 擋下）", 403)] * 3
        mac.run(NOW)
        mac.run(NOW + 300)
        mac.run(NOW + 1200)
        self.assertEqual(mac.meta("upload_status"), "error")
        self.assertIn("第二層上傳失敗（HTTP 403（可能被 Cloudflare 擋下））", mac.log.getvalue())
        mac.run(NOW + 1200 + 3600)
        self.assertEqual(mac.meta("upload_status"), "ok")
        self.assertEqual(self.relay.total(mac.relay_id), 100)

    def test_bad_response_is_a_failure(self):
        mac = self.machine()
        mac.set_tokens(0, 100)
        with mock.patch.object(token_sync, "request_json", return_value={"accepted": 1}), \
                mock.patch.object(token_sync.credentials, "read", return_value=mac.key), redirect_stderr(io.StringIO()):
            token_sync.run(mac.path, now=NOW, config_path=mac.config)
        self.assertEqual(mac.meta("upload_status"), "error")
        self.assertIsNone(mac.meta("relay_device_id"))

    def test_logs_never_contain_keys_urls_or_data(self):
        mac = self.machine()
        mac.set_tokens(0, 123456789)
        self.relay.fail = [HTTPStatusError("HTTP 500", 500), ProviderError("網路錯誤")]
        mac.run(NOW)
        mac.run(NOW + 300)
        self.relay.keys.pop(mac.key)
        mac.run(NOW + 2000)
        mac.run(NOW + 4000)
        text = mac.log.getvalue()
        self.assertIn("HTTP 500", text)
        for secret in (mac.key, URL, "relay.example.dev", "123456789", mac.relay_id):
            self.assertNotIn(secret, text)


class MergeTest(TokenSyncTestCase):
    """ADR-0011：延遲上傳、下載到自己的舊值與重試時，各裝置與合計都不倒退、不重複、歸屬不變。"""

    def setUp(self):
        super().setUp()
        self.mac = self.machine("mac", read_key=READ)
        self.pc = self.machine("pc")

    def test_mac_downloads_other_devices_and_skips_its_own(self):
        self.mac.set_tokens(0, 100)
        self.pc.set_tokens(0, 40)
        self.pc.set_tokens(-1, 10)
        self.pc.run(NOW)
        self.mac.run(NOW)
        self.assertEqual(self.mac.total_by_device(), {self.mac.device_id: 100, self.pc.relay_id: 50})
        devices = self.mac.query("SELECT device_id, name, is_self FROM devices ORDER BY name")
        self.assertEqual(devices, [(self.mac.relay_id, "mac", 1), (self.pc.relay_id, "pc", 0)])
        # PC 沒有讀取密鑰：不下載
        self.assertEqual(self.pc.total_by_device(), {self.pc.device_id: 50})

    def test_downloaded_rows_are_never_uploaded(self):
        self.pc.set_tokens(0, 40)
        self.pc.run(NOW)
        self.mac.set_tokens(0, 100)
        self.mac.run(NOW)
        self.mac.set_tokens(0, 110)
        self.mac.run(NOW + HOUR)
        mac_rows = [r for batch in self.relay.uploads(self.mac.key) for r in batch]
        self.assertEqual([r["input_tokens"] for r in mac_rows], [100, 110])  # 只有本機的列，沒有 PC 的 40
        self.assertEqual(self.relay.total(self.mac.relay_id), 110)
        self.assertEqual(self.relay.total(self.pc.relay_id), 40)
        self.assertEqual(len([k for k in self.relay.rows if k[0] == self.pc.relay_id]), 1)

    def test_old_copy_of_own_rows_does_not_overwrite_newer_local_values(self):
        self.mac.set_tokens(0, 100)
        self.mac.run(NOW)  # 中繼上是 100
        self.mac.set_tokens(0, 150)  # 本機已經 150，還沒到上傳時間
        self.mac.run(NOW + 300)
        self.assertEqual(self.mac.local_total(), 150)
        self.mac.query("DELETE FROM meta WHERE key = 'sync_last_success'")
        self.mac.run(NOW + 600)  # 再下載一次：中繼上自己的 100 被略過
        self.assertEqual(self.mac.total_by_device(), {self.mac.device_id: 150})

    def test_late_upload_from_another_device_is_merged_without_double_counting(self):
        self.pc.set_tokens(-1, 30)
        self.pc.run(NOW)
        self.mac.run(NOW)
        # PC 昨天的紀錄晚到（跨日），一小時後才上傳
        self.pc.set_tokens(-1, 45, now=NOW)
        self.pc.run(NOW + HOUR)
        self.mac.run(NOW + HOUR)
        self.assertEqual(self.mac.total_by_device(), {self.pc.relay_id: 45})
        self.mac.run(NOW + 2 * HOUR)  # 再下載一次也一樣
        self.assertEqual(self.mac.total_by_device(), {self.pc.relay_id: 45})

    def test_retry_after_a_lost_response_does_not_double_count(self):
        self.pc.set_tokens(0, 40)
        self.relay.apply_then_fail = True
        self.pc.run(NOW)  # 中繼寫入了，但 PC 以為失敗
        self.assertEqual(self.pc.meta("upload_status"), "error")
        self.pc.run(NOW + 300)  # 重送同樣的列
        self.assertEqual(self.relay.total(self.pc.relay_id), 40)
        self.assertEqual(len(self.relay.rows), 1)
        self.mac.run(NOW + 300)
        self.assertEqual(self.mac.total_by_device(), {self.pc.relay_id: 40})

    def test_deleted_device_data_disappears_on_the_next_download(self):
        self.pc.set_tokens(0, 40)
        self.pc.run(NOW)
        self.mac.run(NOW)
        self.relay.rows = {k: v for k, v in self.relay.rows.items() if k[0] != self.pc.relay_id}
        self.mac.run(NOW + HOUR)
        self.assertEqual(self.mac.total_by_device(), {})

    def test_revoked_device_is_listed_only_while_the_relay_keeps_its_data(self):
        """撤銷並刪除資料：不再列出；只撤銷：照常列出、標撤銷，本機保留期間外的資料也算「還有資料」"""
        self.pc.set_tokens(-30, 40)
        self.pc.run(NOW)
        self.relay.revoked.add(self.pc.relay_id)
        self.mac.query("UPDATE meta SET value = '7' WHERE key = 'retention_days'")
        self.mac.run(NOW)
        self.assertEqual(self.mac.total_by_device(), {})  # 30 天前的資料在保留期間外，沒有下載
        devices = "SELECT device_id, revoked FROM devices WHERE is_self = 0"
        self.assertEqual(self.mac.query(devices), [(self.pc.relay_id, 1)])
        self.relay.rows = {k: v for k, v in self.relay.rows.items() if k[0] != self.pc.relay_id}  # revoke --delete-data
        self.mac.query("DELETE FROM meta WHERE key = 'sync_last_success'")
        self.mac.run(NOW + 300)
        self.assertEqual(self.mac.query(devices), [])
        # 舊版中繼（沒有 has_data）：無法分辨，照常列出
        self.relay.has_data_field = False
        self.mac.query("DELETE FROM meta WHERE key = 'sync_last_success'")
        self.mac.run(NOW + 600)
        self.assertEqual(self.mac.query(devices), [(self.pc.relay_id, 1)])

    def test_no_download_before_the_own_relay_id_is_known(self):
        self.mac.set_tokens(0, 100)
        self.relay.fail = [ProviderError("網路錯誤")]
        self.mac.run(NOW)  # 上傳失敗：還不知道自己的 device_id
        self.assertEqual([u for u, b in self.relay.calls if b is None], [])

    def test_re_registered_device_reuploads_and_skips_its_old_id(self):
        self.mac.set_tokens(0, 100)
        self.mac.run(NOW)
        old_id = self.mac.relay_id
        # 換成另一台裝置的新密鑰（沒有用 rotate）
        self.mac.key = self.mac.secrets[credentials.DEVICE_KEY] = "aumd_mac2"
        self.mac.relay_id = self.relay.add("aumd_mac2", "mac2")
        self.mac.set_tokens(-1, 5)
        self.mac.run(NOW + HOUR)
        self.assertEqual(self.relay.total(self.mac.relay_id), 105)  # 全部重新上傳到新的 device_id
        self.assertEqual(json.loads(self.mac.meta("relay_device_ids")), sorted([old_id, self.mac.relay_id]))
        self.assertEqual(self.mac.total_by_device(), {self.mac.device_id: 105})  # 舊 id 的列也是自己的：略過

    def test_download_keeps_only_days_within_the_local_retention(self):
        """C-03：保留 7 天的 Mac 不會因為下載而存回 30 天前的資料"""
        self.pc.set_tokens(0, 40)
        self.pc.set_tokens(-30, 7)
        self.pc.run(NOW)
        self.mac.run(NOW)
        self.assertEqual(self.mac.total_by_device(), {self.pc.relay_id: 47})  # 預設保留 365 天
        self.mac.query("UPDATE meta SET value = '7' WHERE key = 'retention_days'")
        self.mac.query("DELETE FROM meta WHERE key = 'sync_last_success'")
        self.mac.run(NOW + 300)
        self.assertEqual(self.mac.total_by_device(), {self.pc.relay_id: 40})
        self.assertEqual(self.mac.query("SELECT MIN(day) FROM daily_tokens"), [(history.local_day(NOW),)])

    def test_forget_removes_other_devices_but_keeps_local_stats(self):
        self.mac.set_tokens(0, 100)
        self.pc.set_tokens(0, 40)
        self.pc.run(NOW)
        self.mac.run(NOW)
        token_sync.forget(self.mac.path)
        self.assertEqual(self.mac.total_by_device(), {self.mac.device_id: 100})
        self.assertEqual(self.mac.query("SELECT COUNT(*) FROM devices"), [(0,)])
        self.assertEqual(self.relay.total(self.pc.relay_id), 40)  # 中繼上的資料不動
        token_sync.forget(self.root / "missing.sqlite3")  # 沒有檔案時不建立
        self.assertFalse((self.root / "missing.sqlite3").exists())

    def test_truncated_download_keeps_the_days_it_did_not_return(self):
        pc = self.pc
        for offset in (-3, -2, -1):
            pc.set_tokens(offset, 10)
        pc.run(NOW)
        self.mac.run(NOW)
        self.assertEqual(self.mac.total_by_device()[pc.relay_id], 30)
        real = self.relay.__call__

        def truncated(url, headers, body=None, timeout=15):
            data = real(url, headers, body, timeout)
            if body is None:  # 中繼只回最新的兩天
                data["rows"] = [r for r in data["rows"] if r["day"] >= history.local_day(NOW - 2 * DAY)]
                data["truncated"] = True
            return data
        self.mac.relay = truncated
        self.mac.run(NOW + DAY)
        self.assertEqual(self.mac.total_by_device()[pc.relay_id], 30)
        self.assertEqual(self.mac.meta("sync_truncated"), "1")
        self.assertEqual(self.mac.log.getvalue().count("超過中繼的列數上限"), 1)

    def test_status_without_a_database_does_not_create_one(self):
        missing = self.root / "none" / "history.sqlite3"
        missing.parent.mkdir()
        self.assertIn("history", token_sync.status(missing))
        self.assertEqual(list(missing.parent.iterdir()), [])

    def test_bad_downloaded_rows_are_skipped(self):
        bad = [
            {"device_id": "not-an-id", "day": "2026-10-14", "provider": "claude", "model": "claude-x", "input_tokens": 1},
            {"device_id": str(uuid.uuid4()), "day": "2026-10-14", "provider": "gemini", "model": "claude-x"},
            {"device_id": str(uuid.uuid4()), "day": "2026-10-14", "provider": "claude", "model": "secret project"},
            {"device_id": str(uuid.uuid4()), "day": "2026-10-14", "provider": "claude", "model": "claude-x", "input_tokens": -1},
            {"device_id": str(uuid.uuid4()), "day": "14/10/2026", "provider": "claude", "model": "claude-x"},
            "x",
        ]
        self.mac.run(NOW)
        conn = history.connect(self.mac.path)
        try:
            with mock.patch.object(token_sync, "request_json", return_value={"devices": [], "rows": bad}):
                self.assertEqual(token_sync.download(conn, URL, READ, NOW), 0)
        finally:
            conn.close()


class MainTest(unittest.TestCase):
    def test_tokens_only_runs_sync_without_changing_the_exit_code(self):
        with mock.patch.object(cli.token_stats, "run_safely", return_value=True), \
                mock.patch.object(cli.token_sync, "run_safely") as sync:
            self.assertEqual(cli.main(["--tokens-only", "--quiet"]), 0)
        sync.assert_called_once()

    def test_run_safely_never_raises(self):
        with mock.patch.object(token_sync, "run", side_effect=RuntimeError("/Users/someone")), \
                redirect_stderr(io.StringIO()) as err:
            token_sync.run_safely()
        self.assertIn("RuntimeError", err.getvalue())
        self.assertNotIn("/Users/someone", err.getvalue())


@unittest.skipUnless(sys.platform == "win32", "Windows 認證管理員")
class WindowsCredentialTest(unittest.TestCase):
    def test_store_read_delete(self):
        name = credentials.DEVICE_KEY
        target = f"AIUsageMonitor-test/{uuid.uuid4()}"
        with mock.patch.object(credentials, "target", lambda n: target):
            credentials.store(name, "aumd_測試")
            try:
                self.assertEqual(credentials.read(name), "aumd_測試")
            finally:
                credentials.delete(name)
            self.assertIsNone(credentials.read(name))


if __name__ == "__main__":
    unittest.main()
