from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone

# 輸出 JSON 有不相容變更時遞增（FR-13）
SCHEMA_VERSION = 1
# 與中繼的 LIMITS.maxPct 相同：更大的值會讓中繼拒收整份快照（連其他服務的資料一起），改在這裡報錯
MAX_PCT = 1000
PCT_ERROR = "用量百分比缺少或格式不正確，API 可能已變更"


def iso_utc(dt: datetime) -> str:
    """統一輸出成 2026-10-20T09:30:00Z 格式。"""
    return dt.astimezone(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    """Python 3.10 的 fromisoformat 不認得結尾的 Z，先換成 +00:00。"""
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def parse_pct(value: object) -> float:
    """API 回應中的使用百分比。缺少、null 或不是有限的非負數時報錯：
    不能當成 0（畫面會顯示「完全沒用」），NaN 也會讓輸出的 JSON 不合法。
    超過 100（超額）照實傳出，顯示端會限制在 0～100；超過 MAX_PCT 視為格式不正確。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProviderError(PCT_ERROR)
    try:
        pct = float(value)  # 超大的整數（10**400）轉不成 float：同樣是格式不正確
    except OverflowError:
        raise ProviderError(PCT_ERROR) from None
    if not math.isfinite(pct) or not 0 <= pct <= MAX_PCT:
        raise ProviderError(PCT_ERROR)
    return pct


@dataclass
class Window:
    id: str
    label: str
    used_pct: float
    resets_at: datetime | None
    hidden: bool = False  # 次要額度（如各模型的每週上限），iOS 端預設不顯示

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "label": self.label,
            "used_pct": round(self.used_pct, 1),
            "resets_at": iso_utc(self.resets_at) if self.resets_at else None,
            "hidden": self.hidden,
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
