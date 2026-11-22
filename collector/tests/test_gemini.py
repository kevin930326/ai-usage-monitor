import copy
import json
import os
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

from usage_collector.models import ProviderError
from usage_collector.providers import gemini

FIXTURES = Path(__file__).parent / "fixtures" / "gemini"
SUMMARY = json.loads((FIXTURES / "quota-summary-pro.json").read_text())
TOKEN = "csrf-secret-123"
OK_REPLY = (200, json.dumps(SUMMARY).encode())


def summary(**changes) -> dict:
    """實際回應的副本；changes 以 bucketId 為 key 改寫該額度的欄位（值為 None 時刪掉欄位）。"""
    data = copy.deepcopy(SUMMARY)
    for group in data["response"]["groups"]:
        for bucket in group["buckets"]:
            for key, value in changes.get(bucket["bucketId"], {}).items():
                if value is None:
                    bucket.pop(key, None)
                else:
                    bucket[key] = value
    return data


class FakeServer:
    """假的 language server：記錄收到的請求，依 `reply` 回應（(狀態碼, 內容 bytes)）。"""

    def __init__(self, reply=OK_REPLY):
        self.reply = reply
        self.requests: list[dict] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                server.requests.append({"path": self.path, "body": body,
                                        "headers": {k.lower(): v for k, v in self.headers.items()}})
                status, content = server.reply
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, *args):
                pass

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()


def write_daemon(directory: Path, port: int, pid: int | None = None, name: str = "hub_1.json", **extra) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(json.dumps({"pid": pid or os.getpid(), "httpsPort": 1, "httpPort": port,
                                "lsVersion": "2.33.0", "csrfToken": TOKEN, **extra}))
    return path


class ParseTest(unittest.TestCase):
    def test_real_response(self):
        usage = gemini.parse(SUMMARY)
        self.assertIsNone(usage.plan)
        self.assertEqual([(w.id, w.label, w.hidden) for w in usage.windows], [
            ("five_hour", "5 小時", False),
            ("weekly", "每週", False),
            ("weekly_claude_gpt", "每週 Claude／GPT", True),
            ("five_hour_claude_gpt", "5 小時 Claude／GPT", True),
            ("weekly_argon", "每週 Argon", True),
        ])
        five, weekly = usage.windows[:2]
        self.assertAlmostEqual(five.used_pct, 2.0, places=1)
        self.assertAlmostEqual(weekly.used_pct, 10.4, places=1)
        self.assertEqual(five.resets_at, datetime(2026, 11, 22, 20, 0, 2, tzinfo=timezone.utc))
        self.assertEqual(weekly.resets_at, datetime(2026, 11, 28, 9, 0, 2, tzinfo=timezone.utc))

    def test_unused_buckets_have_no_reset_time(self):
        # 還沒用的額度，resetTime 每次查都往後移：不當成重置時間
        for window in gemini.parse(SUMMARY).windows[2:]:
            self.assertEqual(window.used_pct, 0)
            self.assertIsNone(window.resets_at)

    def test_missing_fraction_means_used_up(self):
        usage = gemini.parse(summary(**{"gemini-5h": {"remainingFraction": None}}))
        self.assertEqual(usage.windows[0].used_pct, 100)
        self.assertIsNotNone(usage.windows[0].resets_at)

    def test_fractional_seconds_in_reset_time(self):
        usage = gemini.parse(summary(**{"gemini-5h": {"resetTime": "2026-11-22T20:00:02.123456789Z"}}))
        self.assertEqual(usage.windows[0].resets_at, datetime(2026, 11, 22, 20, 0, 2, tzinfo=timezone.utc))

    def test_bad_values_are_format_changes(self):
        for bad in (1.5, -0.1, "0.5", True, float("nan")):
            with self.subTest(bad=bad), self.assertRaises(ProviderError) as e:
                gemini.parse(summary(**{"gemini-weekly": {"remainingFraction": bad}}))
            self.assertEqual(str(e.exception), gemini.FORMAT_CHANGED)
        for bad in ("tomorrow", 1793094310, "2026-11-28T09:00:02"):
            with self.subTest(bad=bad), self.assertRaises(ProviderError):
                gemini.parse(summary(**{"gemini-weekly": {"resetTime": bad}}))
        for data in ({}, {"response": {}}, {"response": {"groups": [{"buckets": "x"}]}}):
            with self.subTest(data=data), self.assertRaises(ProviderError):
                gemini.parse(data)

    def test_unknown_buckets_are_skipped(self):
        data = summary()
        data["response"]["groups"].append({"buckets": [
            {"bucketId": "new-daily", "window": "daily", "remainingFraction": 0.5},
            {"bucketId": "gemini-monthly", "window": "monthly", "remainingFraction": 0.5},
        ]})
        self.assertEqual(len(gemini.parse(data).windows), 5)

    def test_duplicate_bucket_is_format_change(self):
        data = summary()
        data["response"]["groups"][0]["buckets"].append(dict(data["response"]["groups"][0]["buckets"][0]))
        with self.assertRaises(ProviderError):
            gemini.parse(data)

    def test_no_gemini_quota(self):
        data = summary()
        data["response"]["groups"] = data["response"]["groups"][1:]
        with self.assertRaises(ProviderError) as e:
            gemini.parse(data)
        self.assertIn("沒有 Gemini 額度", str(e.exception))

    def test_output_has_no_descriptions(self):
        # 只留額度數字：說明文字（英文、可能改版）不進快照
        out = json.dumps([w.to_dict() for w in gemini.parse(SUMMARY).windows], ensure_ascii=False)
        self.assertNotIn("refresh", out)
        self.assertNotIn("Models", out)


class FindServerTest(unittest.TestCase):
    def test_not_running_when_no_file(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(ProviderError) as e:
            gemini.find_server(Path(d) / "daemon")
        self.assertEqual(str(e.exception), gemini.NOT_RUNNING)

    def test_skips_dead_and_broken_files(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            (directory / "hub_9.json").write_text("not json")
            write_daemon(directory, 1111, name="hub_2.json", csrfToken="")
            dead = write_daemon(directory, 2222, pid=999999, name="hub_3.json")
            good = write_daemon(directory, 3333, name="hub_4.json")
            os.utime(good, (1, 1))  # 最舊的才是唯一活著的
            os.utime(dead, (2, 2))
            with mock.patch.object(gemini, "pid_alive", side_effect=lambda pid: pid == os.getpid()):
                self.assertEqual(gemini.find_server(directory), (3333, TOKEN))

    def test_newest_live_file_wins(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            old = write_daemon(directory, 1111, name="hub_1.json")
            write_daemon(directory, 2222, name="hub_2.json")
            os.utime(old, (1, 1))
            self.assertEqual(gemini.find_server(directory)[0], 2222)


class FetchTest(unittest.TestCase):
    def fetch(self, server: FakeServer):
        with tempfile.TemporaryDirectory() as d:
            write_daemon(Path(d), server.port)
            with mock.patch.object(gemini, "daemon_dir", return_value=Path(d)):
                return gemini.fetch()

    def test_request_shape(self):
        with FakeServer() as server:
            usage = self.fetch(server)
        self.assertEqual(usage.windows[0].id, "five_hour")
        [req] = server.requests
        self.assertEqual(req["path"], gemini.METHOD)
        self.assertEqual(json.loads(req["body"]), {"forceRefresh": True})
        self.assertEqual(req["headers"]["x-codeium-csrf-token"], TOKEN)

    def test_ignores_proxy_settings(self):
        with FakeServer() as server, mock.patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:1", "HTTP_PROXY": "http://127.0.0.1:1"}):
            self.assertEqual(len(self.fetch(server).windows), 5)

    def test_errors_do_not_leak_token_or_message(self):
        cases = [
            ((401, b'{"code": "unauthenticated", "message": "person@example.com"}'), "尚未登入 Antigravity"),
            ((403, b'{"code": "permission_denied", "message": "bad csrf"}'), "拒絕連線"),
            ((500, b'{"code": "internal", "message": "person@example.com"}'), "HTTP 500"),
            ((200, b"not json"), gemini.FORMAT_CHANGED),
            ((200, b"[]"), gemini.FORMAT_CHANGED),
        ]
        for reply, expected in cases:
            with self.subTest(reply=reply), FakeServer(reply) as server, self.assertRaises(ProviderError) as e:
                self.fetch(server)
            self.assertIn(expected, str(e.exception))
            self.assertNotIn("@", str(e.exception))
            self.assertNotIn(TOKEN, str(e.exception))

    def test_closed_port_is_not_running(self):
        with FakeServer() as server:
            port = server.port
        with tempfile.TemporaryDirectory() as d:
            write_daemon(Path(d), port)
            with mock.patch.object(gemini, "daemon_dir", return_value=Path(d)), self.assertRaises(ProviderError) as e:
                gemini.fetch()
        self.assertEqual(str(e.exception), gemini.NOT_RUNNING)

    def test_oversized_response(self):
        with FakeServer((200, b" " * (gemini.MAX_OUTPUT + 10))) as server, self.assertRaises(ProviderError) as e:
            self.fetch(server)
        self.assertEqual(str(e.exception), gemini.FORMAT_CHANGED)


class SourceTest(unittest.TestCase):
    def test_only_quota_method(self):
        """只呼叫額度摘要：不開對話、不呼叫會回傳 email 的 GetUserStatus（ADR-0022）。"""
        source = Path(gemini.__file__).read_text()
        for forbidden in ("GetUserStatus\"", "/GetUserStatus", "SendUserCascadeMessage", "StartCascade", "agentapi"):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
