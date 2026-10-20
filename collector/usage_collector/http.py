from __future__ import annotations

import json
import urllib.error
import urllib.request

from . import __version__
from .models import ProviderError

USER_AGENT = f"ai-usage-monitor/{__version__}"


def request_json(url: str, headers: dict[str, str], body: dict | None = None, timeout: float = 15) -> dict:
    data = None
    headers = {"User-Agent": USER_AGENT, **headers}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise ProviderError(f"驗證失敗 (HTTP {e.code})，請重新登入") from None
        raise ProviderError(f"HTTP {e.code}") from None
    except urllib.error.URLError:
        raise ProviderError("網路錯誤") from None
    except json.JSONDecodeError:
        raise ProviderError("回應不是 JSON，API 可能已變更") from None


def get_json(url: str, headers: dict[str, str], timeout: float = 15) -> dict:
    return request_json(url, headers, timeout=timeout)


def post_json(url: str, headers: dict[str, str], body: dict, timeout: float = 15) -> dict:
    return request_json(url, headers, body=body, timeout=timeout)
