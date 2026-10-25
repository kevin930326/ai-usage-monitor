from __future__ import annotations

import json
import socket
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from usage_collector.http import USER_AGENT, post_json, request_json
from usage_collector.models import ProviderError


class Server:
    """本機 HTTP 伺服器：記錄收到的 Authorization 與 User-Agent，依 routes 回應或重新導向。"""

    def __init__(self, routes: dict[str, str] | None = None, errors: dict[str, tuple[int, bytes]] | None = None):
        self.routes = routes or {}
        self.errors = errors or {}
        self.seen: list[tuple[str, str | None]] = []
        self.agents: list[str | None] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self):
                outer.seen.append((self.path, self.headers.get("Authorization")))
                outer.agents.append(self.headers.get("User-Agent"))
                if self.path in outer.routes:
                    self.send_response(302)
                    self.send_header("Location", outer.routes[self.path])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if self.path in outer.errors:
                    status, body = outer.errors[self.path]
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                body = json.dumps({"path": self.path}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self.respond()

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.respond()

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class RedirectTest(unittest.TestCase):
    """C-03：含 Bearer 密鑰的請求不能被重新導向帶到其他來源（NFR-1）。"""

    def setUp(self):
        self.other = Server()
        self.origin = Server()
        self.addCleanup(self.other.close)
        self.addCleanup(self.origin.close)
        self.headers = {"Authorization": "Bearer secret-token"}

    def test_cross_origin_redirect_does_not_forward_token(self):
        self.origin.routes["/usage"] = f"{self.other.origin}/steal"
        with self.assertRaises(ProviderError) as ctx:
            request_json(f"{self.origin.origin}/usage", self.headers)
        self.assertNotIn("secret-token", str(ctx.exception))
        self.assertEqual(self.other.seen, [])

    def test_cross_origin_redirect_of_post_does_not_forward_token(self):
        self.origin.routes["/usage"] = f"{self.other.origin}/steal"
        with self.assertRaises(ProviderError):
            post_json(f"{self.origin.origin}/usage", self.headers, {"v": 1})
        self.assertEqual(self.other.seen, [])

    def test_redirect_to_other_port_on_same_host_is_cross_origin(self):
        # 同一台主機、不同 port 仍是不同來源
        self.origin.routes["/usage"] = self.other.origin.replace("127.0.0.1", "localhost") + "/steal"
        with self.assertRaises(ProviderError):
            request_json(f"{self.origin.origin}/usage", self.headers)
        self.assertEqual(self.other.seen, [])

    def test_same_origin_redirect_is_followed(self):
        self.origin.routes["/usage"] = "/usage/"
        self.assertEqual(request_json(f"{self.origin.origin}/usage", self.headers), {"path": "/usage/"})
        self.assertEqual(self.origin.seen[-1], ("/usage/", "Bearer secret-token"))

    def test_redirect_loop_is_an_error(self):
        self.origin.routes["/a"] = "/b"
        self.origin.routes["/b"] = "/a"
        with self.assertRaises(ProviderError):
            request_json(f"{self.origin.origin}/a", self.headers)



class SilentServer:
    """接受連線後不回應（sleep 秒）或直接關閉連線，模擬讀取回應時逾時或中斷。"""

    def __init__(self, sleep: float | None):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen()
        self.origin = f"http://127.0.0.1:{self.sock.getsockname()[1]}"
        self.sleep = sleep
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        try:
            conn, _ = self.sock.accept()
        except OSError:
            return
        with conn:
            conn.recv(65536)
            if self.sleep:
                time.sleep(self.sleep)

    def close(self):
        self.sock.close()


class ReadFailureTest(unittest.TestCase):
    """連上中繼後讀取回應逾時或連線被中斷：要變成 ProviderError，不能讓收集器整個中斷（之後的歷史、統計、服務狀態都不寫）。"""

    def check(self, sleep: float | None):
        server = SilentServer(sleep)
        self.addCleanup(server.close)
        with self.assertRaises(ProviderError) as ctx:
            post_json(f"{server.origin}/usage", {"Authorization": "Bearer w"}, {"schema_version": 1}, timeout=0.3)
        self.assertEqual(str(ctx.exception), "網路錯誤（連線逾時或中斷）")

    def test_read_timeout(self):
        self.check(sleep=2)

    def test_connection_closed_without_response(self):
        self.check(sleep=None)


class ErrorReasonTest(unittest.TestCase):
    """中繼 API 拒絕快照時（C-12 的 422），日誌要看得到它回的原因；其他回應只留狀態碼。"""

    def request(self, status: int, body: bytes) -> str:
        server = Server(errors={"/usage": (status, body)})
        self.addCleanup(server.close)
        with self.assertRaises(ProviderError) as ctx:
            post_json(f"{server.origin}/usage", {"Authorization": "Bearer w"}, {"schema_version": 1})
        return str(ctx.exception)

    def test_relay_reason_is_included(self):
        self.assertEqual(self.request(422, b'{"error": "claude\uff1aused_pct \u4e0d\u5408\u6cd5"}'),
                         "HTTP 422：claude：used_pct 不合法")

    def test_other_bodies_are_not_echoed(self):
        self.assertEqual(self.request(422, b"<html>oops</html>"), "HTTP 422")
        self.assertEqual(self.request(422, b'{"error": 5}'), "HTTP 422")
        self.assertEqual(self.request(422, json.dumps({"error": "x" * 201}).encode()), "HTTP 422")
        self.assertEqual(self.request(422, b'{"error": "two\nlines"}'), "HTTP 422")
        self.assertEqual(self.request(500, b'{"error": "internal"}'), "HTTP 500")


class UserAgentTest(unittest.TestCase):
    """Cloudflare 以 403 擋下 urllib 預設的「Python-urllib/3.x」：每個請求都要帶收集器自己的 User-Agent。"""

    def test_every_request_sends_the_collector_user_agent(self):
        server = Server()
        self.addCleanup(server.close)
        request_json(f"{server.origin}/tokens/daily?from=2026-01-01", {"Authorization": "Bearer r"})
        request_json(f"{server.origin}/tokens/daily", {"Authorization": "Bearer w"}, body={"rows": []})
        post_json(f"{server.origin}/usage", {"Authorization": "Bearer w"}, {"schema_version": 1})
        request_json(f"{server.origin}/api/v2/summary.json", {})
        self.assertEqual(server.agents, [USER_AGENT] * 4)
        self.assertRegex(USER_AGENT, r"^ai-usage-monitor/\d+\.\d+")

    def test_same_origin_redirect_keeps_the_user_agent(self):
        server = Server(routes={"/usage": "/usage/"})
        self.addCleanup(server.close)
        request_json(f"{server.origin}/usage", {"Authorization": "Bearer w"})
        self.assertEqual(server.agents, [USER_AGENT] * 2)

    def test_only_http_py_makes_requests(self):
        # 其他模組都經過 request_json（才會帶 User-Agent、只跟隨同源的重新導向）；providers 透過 CLI，不直接連網
        package = Path(__file__).resolve().parent.parent / "usage_collector"
        offenders = [str(f.relative_to(package)) for f in sorted(package.rglob("*.py")) if f.name != "http.py"
                     and any(m in f.read_text(encoding="utf-8")
                             for m in ("urllib.request", "http.client", "urlopen", "import socket", "import requests"))]
        self.assertEqual(offenders, [])


class EdgeResponseTest(unittest.TestCase):
    """Cloudflare 邊緣的 403 或非 JSON 回應：日誌要看得出狀態碼與可能的原因，不帶內容、網址與密鑰。"""

    def error(self, path: str, status: int, body: bytes, headers: dict | None = None) -> str:
        server = Server(errors={path: (status, body)})
        self.addCleanup(server.close)
        with self.assertRaises(ProviderError) as ctx:
            request_json(f"{server.origin}{path}", headers or {"Authorization": "Bearer secret-token"})
        text = str(ctx.exception)
        self.assertNotIn("secret-token", text)
        self.assertNotIn("127.0.0.1", text)
        return text

    def test_403_without_a_relay_reason_points_at_cloudflare(self):
        self.assertEqual(self.error("/tokens/daily", 403, b"error code: 1010"), "HTTP 403（可能被 Cloudflare 擋下）")

    def test_403_from_the_relay_keeps_its_reason(self):
        self.assertEqual(self.error("/pair", 403, '{"error": "配對失敗"}'.encode()), "HTTP 403：配對失敗")

    def test_non_json_success_includes_the_status(self):
        text = self.error("/usage", 200, b"<html>Just a moment...</html>")
        self.assertEqual(text, "回應不是 JSON（HTTP 200），可能被 Cloudflare 擋下或 API 已變更")
        self.assertNotIn("Just a moment", text)

    def test_invalid_header_is_not_reported_as_a_bad_response(self):
        # 密鑰貼進了換行或全形字：http.client 在送出前就拒絕，不能被說成「回應不是 JSON」
        for key in ("aumd_abc\ndef", "aumd_ａｂｃ"):
            server = Server()
            self.addCleanup(server.close)
            with self.assertRaises(ProviderError) as ctx:
                request_json(f"{server.origin}/tokens/daily", {"Authorization": f"Bearer {key}"})
            self.assertEqual(str(ctx.exception), "請求標頭含有無效字元，密鑰可能貼錯")
            self.assertEqual(server.seen, [])


if __name__ == "__main__":
    unittest.main()
