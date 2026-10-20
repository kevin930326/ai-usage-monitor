"""用法：python3 -m usage_collector [--compact]"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

from .models import ProviderError, ProviderUsage, iso_utc
from .providers import PROVIDERS


def collect() -> dict:
    providers = {}
    for name, module in PROVIDERS.items():
        try:
            usage = module.fetch()
        except ProviderError as e:
            usage = ProviderUsage(error=str(e))
        except Exception as e:  # 單一 provider 壞掉不能拖垮整份輸出
            usage = ProviderUsage(error=f"未預期的錯誤：{type(e).__name__}")
        providers[name] = usage.to_dict()
    return {"updated_at": iso_utc(datetime.now(timezone.utc)), "providers": providers}


def main() -> int:
    parser = argparse.ArgumentParser(description="收集 Claude 與 Codex 的用量")
    parser.add_argument("--compact", action="store_true", help="輸出單行 JSON")
    args = parser.parse_args()

    snapshot = collect()
    json.dump(snapshot, sys.stdout, ensure_ascii=False, indent=None if args.compact else 2)
    print()
    # 全部失敗時回傳非 0，方便 launchd / 腳本判斷
    return 0 if any(p["error"] is None for p in snapshot["providers"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
