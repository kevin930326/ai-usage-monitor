from __future__ import annotations

import json
import urllib.error
import urllib.request

from . import __version__
from .models import ProviderError

USER_AGENT = f"ai-usage-monitor/{__version__}"


def get_json(url: str, headers: dict[str, str], timeout: float = 15) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise ProviderError(f"驗證失敗 (HTTP {e.code})，請重新登入") from None
        raise ProviderError(f"HTTP {e.code}") from None
    except urllib.error.URLError:
        raise ProviderError("網路錯誤") from None
    except json.JSONDecodeError:
        raise ProviderError("回應不是 JSON，API 可能已變更") from None
