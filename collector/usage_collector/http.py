from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from . import __version__
from .models import ProviderError

USER_AGENT = f"ai-usage-monitor/{__version__}"


def _origin(url: str) -> tuple[str, str | None, int | None]:
    parts = urllib.parse.urlsplit(url)
    return parts.scheme, parts.hostname, parts.port or {"http": 80, "https": 443}.get(parts.scheme)


class _SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    """預設的重新導向會把 Authorization 原封不動帶到新網址，且不檢查來源（含 HTTPS→HTTP）。
    請求都帶著 Bearer 密鑰（NFR-1），只跟隨同一個 scheme、主機與 port 的重新導向。"""

    max_redirections = 3

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if _origin(newurl) != _origin(req.full_url):
            raise ProviderError("伺服器要求重新導向到其他網址，為保護密鑰已拒絕")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_SameOriginRedirectHandler)


def _reason(e: urllib.error.HTTPError) -> str:
    """4xx 回應若帶我們自己的 `{"error": "…"}`（中繼 API 的驗證訊息），把原因附在錯誤後面，
    否則日誌只有「HTTP 422」看不出哪個欄位被拒。只取短的純文字，不帶其他內容。"""
    if not 400 <= e.code < 500:
        return ""
    try:
        reason = json.loads(e.read(2048)).get("error")
    except (ValueError, AttributeError, OSError):
        return ""
    if not isinstance(reason, str) or not reason or len(reason) > 200 or "\n" in reason:
        return ""
    return f"：{reason}"


def request_json(url: str, headers: dict[str, str], body: dict | None = None, timeout: float = 15) -> dict:
    data = None
    headers = {"User-Agent": USER_AGENT, **headers}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with _opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            raise ProviderError(f"伺服器要求重新導向（HTTP {e.code}），已停止") from None
        if e.code in (401, 403):
            raise ProviderError(f"驗證失敗 (HTTP {e.code})，請重新登入") from None
        raise ProviderError(f"HTTP {e.code}{_reason(e)}") from None
    except urllib.error.URLError:
        raise ProviderError("網路錯誤") from None
    except json.JSONDecodeError:
        raise ProviderError("回應不是 JSON，API 可能已變更") from None


def get_json(url: str, headers: dict[str, str], timeout: float = 15) -> dict:
    return request_json(url, headers, timeout=timeout)


def post_json(url: str, headers: dict[str, str], body: dict, timeout: float = 15) -> dict:
    return request_json(url, headers, body=body, timeout=timeout)
