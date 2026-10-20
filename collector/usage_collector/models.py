from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone


def iso_utc(dt: datetime) -> str:
    """統一輸出成 2026-10-20T09:30:00Z 格式。"""
    return dt.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Window:
    id: str
    label: str
    used_pct: float
    resets_at: datetime | None

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "label": self.label,
            "used_pct": round(self.used_pct, 1),
            "resets_at": iso_utc(self.resets_at) if self.resets_at else None,
        }


@dataclass
class ProviderUsage:
    plan: str | None = None
    windows: list[Window] = field(default_factory=list)
    error: str | None = None

    def to_dict(self) -> dict:
        return {
            "plan": self.plan,
            "error": self.error,
            "windows": [w.to_dict() for w in self.windows],
        }


class ProviderError(Exception):
    """可以直接顯示給使用者的錯誤。訊息裡絕不能含 token。"""
