"""用法：python3 -m usage_collector [--compact] [--write-local] [--upload] [--quiet]"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

from . import local_store, relay
from .models import SCHEMA_VERSION, ProviderError, ProviderUsage, iso_utc
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
    return {
        "schema_version": SCHEMA_VERSION,
        "updated_at": iso_utc(datetime.now(timezone.utc)),
        "providers": providers,
    }


def log(message: str) -> None:
    # launchd 會把 stderr 導到日誌檔，加上時間方便追查
    print(f"[{iso_utc(datetime.now(timezone.utc))}] {message}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="收集 Claude 與 Codex 的用量")
    parser.add_argument("--compact", action="store_true", help="輸出單行 JSON")
    parser.add_argument("--write-local", action="store_true", help="寫入本機 usage.json")
    parser.add_argument("--upload", action="store_true", help="上傳到中繼 API（未設定時略過）")
    parser.add_argument("--quiet", action="store_true", help="不在 stdout 輸出 JSON")
    args = parser.parse_args(argv)

    snapshot = collect()
    ok = any(p["error"] is None for p in snapshot["providers"].values())
    for name, p in snapshot["providers"].items():
        if p["error"]:
            log(f"{name}: {p['error']}")

    if not args.quiet:
        json.dump(snapshot, sys.stdout, ensure_ascii=False, indent=None if args.compact else 2)
        print()

    if args.write_local:
        local_store.write_snapshot(snapshot)

    if args.upload:
        try:
            relay.upload(snapshot)
        except relay.RelayNotConfigured as e:
            log(f"略過上傳：{e}")
        except ProviderError as e:
            log(str(e))
            ok = False

    # 全部 provider 失敗或上傳失敗時回傳非 0，方便 launchd / 腳本判斷
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
