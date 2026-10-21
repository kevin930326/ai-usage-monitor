from __future__ import annotations

import sys
from datetime import datetime, timezone

from .models import iso_utc


def log(message: str) -> None:
    # launchd 會把 stderr 導到日誌檔，加上時間方便追查
    print(f"[{iso_utc(datetime.now(timezone.utc))}] {message}", file=sys.stderr)
