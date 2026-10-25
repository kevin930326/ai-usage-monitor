"""HTTP 用戶端，只用來上傳快照到自己的中繼 API（relay.py）。

收集器不直接呼叫任何服務的用量端點（ADR-0006、ADR-0007），這裡唯一帶的密鑰是中繼的上傳密鑰。"""
from __future__ import annotations

import http.client
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request

from . import __version__
from .models import ProviderError

# 每個請求都帶（tests/test_http.py 檢查）：Cloudflare 會以 403 擋下 urllib 預設的「Python-urllib/3.x」
USER_AGENT = f"ai-usage-monitor/{__version__}"
CLOUDFLARE_HINT = "（可能被 Cloudflare 擋下）"


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


class HTTPStatusError(ProviderError):
    """伺服器回了錯誤狀態碼；`status` 讓呼叫端分辨 401／403（密鑰失效）與其他失敗（第二層的上傳）。"""

    def __init__(self, message: str, status: int):
        super().__init__(message)
        self.status = status


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
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            raise ProviderError(f"伺服器要求重新導向（HTTP {e.code}），已停止") from None
        if e.code == 401:
            raise HTTPStatusError(f"驗證失敗 (HTTP {e.code})，請重新登入", e.code) from None
        if e.code == 403:
            # 中繼自己只有 /pair 回 403（帶 {"error": …}）；其他 403 來自 Cloudflare 邊緣（WAF、Bot Fight Mode）
            raise HTTPStatusError(f"HTTP 403{_reason(e) or CLOUDFLARE_HINT}", e.code) from None
        raise HTTPStatusError(f"HTTP {e.code}{_reason(e)}", e.code) from None
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLCertVerificationError):
            raise ProviderError("網路錯誤（HTTPS 憑證驗證失敗）") from None
        raise ProviderError("網路錯誤") from None
    # 送出前被 http.client 拒絕：標頭含有換行或 Latin-1 以外的字元（例如貼錯的密鑰）
    except ValueError:
        raise ProviderError("請求標頭含有無效字元，密鑰可能貼錯") from None
    # 連上之後讀取回應時逾時（TimeoutError）、連線被中斷或回應不完整：urllib 不會包成 URLError
    except (OSError, http.client.HTTPException):
        raise ProviderError("網路錯誤（連線逾時或中斷）") from None
    try:
        return json.loads(raw) if raw else {}
    except ValueError:  # JSONDecodeError，以及不是 UTF-8 的回應（UnicodeDecodeError）
        raise ProviderError(f"回應不是 JSON（HTTP {status}），可能被 Cloudflare 擋下或 API 已變更") from None


def post_json(url: str, headers: dict[str, str], body: dict, timeout: float = 15) -> dict:
    return request_json(url, headers, body=body, timeout=timeout)
