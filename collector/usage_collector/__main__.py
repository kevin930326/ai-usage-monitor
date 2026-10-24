"""用法：python3 -m usage_collector [--compact] [--write-local] [--upload] [--quiet] [--tokens-only] [--log-file 檔案]"""
from __future__ import annotations

import argparse
import json
import signal
import sys
from datetime import datetime, timezone

from . import history, local_store, relay, service_status, token_stats
from .log import log
from .models import SCHEMA_VERSION, ProviderError, ProviderUsage, iso_utc
from .providers import PROVIDERS, enabled_providers


def collect(enabled: list[str] | None = None) -> dict:
    providers = {}
    for name in enabled_providers() if enabled is None else enabled:
        module = PROVIDERS[name]
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="收集 Claude 與 Codex 的用量")
    parser.add_argument("--compact", action="store_true", help="輸出單行 JSON")
    parser.add_argument("--write-local", action="store_true", help="寫入本機 usage.json")
    parser.add_argument("--upload", action="store_true", help="上傳到中繼 API（未設定時略過）")
    parser.add_argument("--quiet", action="store_true", help="不在 stdout 輸出 JSON")
    parser.add_argument("--tokens-only", action="store_true",
                        help="只統計本機 Token，不收集額度（Windows 排程的預設，ADR-0011 第 2 節）")
    parser.add_argument("--log-file", help="日誌附加到這個檔案（Windows 的 pythonw 沒有 stderr）")
    args = parser.parse_args(argv)
    if args.log_file:
        sys.stderr = open(args.log_file, "a", encoding="utf-8", buffering=1)  # 用到程序結束

    if args.tokens_only:
        # 不執行 claude／codex、不寫 usage.json、不上傳：只有 Token 統計（本機）
        token_stats.run_safely()
        return 0

    snapshot = collect()
    if not snapshot["providers"]:
        log("config.json 的 enabled_providers 沒有啟用任何服務，"
            "登入 Claude Code 或 Codex CLI 後重新執行 scripts/install-launchd.sh")
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

    # 額度歷史（ADR-0009）放在最後：鎖住時最多等 5 秒，不能拖慢 usage.json 與上傳；失敗只記日誌、不影響結束碼
    if args.write_local:
        history.record_safely(snapshot)
        # Token 統計（ADR-0009）：最後執行、降低優先順序；首次掃描每次最多 64 MB 或 15 秒
        token_stats.run_safely()
        # 服務狀態（FR-45）：公開狀態頁，只寫本機 service-status.json、不上傳；至少間隔 4 分鐘
        service_status.update_safely(list(snapshot["providers"]))

    # 全部 provider 失敗或上傳失敗時回傳非 0，方便 launchd / 腳本判斷
    return 0 if ok else 1


if __name__ == "__main__":
    # launchd 停止工作時送 SIGTERM：轉成 SystemExit，讓 provider 的清理（關閉 codex app-server）照常執行
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    sys.exit(main())
