from __future__ import annotations

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from usage_collector.http import get_json, post_json
from usage_collector.models import ProviderError


class Server:
    """本機 HTTP 伺服器：記錄收到的 Authorization，依 routes 回應或重新導向。"""

    def __init__(self, routes: dict[str, str] | None = None, errors: dict[str, tuple[int, bytes]] | None = None):
        self.routes = routes or {}
        self.errors = errors or {}
        self.seen: list[tuple[str, str | None]] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self):
                outer.seen.append((self.path, self.headers.get("Authorization")))
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
            get_json(f"{self.origin.origin}/usage", self.headers)
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
            get_json(f"{self.origin.origin}/usage", self.headers)
        self.assertEqual(self.other.seen, [])

    def test_same_origin_redirect_is_followed(self):
        self.origin.routes["/usage"] = "/usage/"
        self.assertEqual(get_json(f"{self.origin.origin}/usage", self.headers), {"path": "/usage/"})
        self.assertEqual(self.origin.seen[-1], ("/usage/", "Bearer secret-token"))

    def test_redirect_loop_is_an_error(self):
        self.origin.routes["/a"] = "/b"
        self.origin.routes["/b"] = "/a"
        with self.assertRaises(ProviderError):
            get_json(f"{self.origin.origin}/a", self.headers)



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


if __name__ == "__main__":
    unittest.main()
