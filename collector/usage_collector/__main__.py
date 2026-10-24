"""用法：python3 -m usage_collector [--compact] [--write-local] [--upload] [--quiet] [--agent app]
                                  [--tokens-only] [--log-file 檔案]"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from pathlib import Path

from . import history, local_store, paths, relay, service_status, token_stats
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


# install-launchd.sh 安裝的收集器（ADR-0013 第 3 節）。App 內建的收集器在它存在時不執行，避免每 5 分鐘跑兩次、重複上傳
LEGACY_LABEL = "io.github.kevin930326.ai-usage-monitor"


def launch_agents_dir(environ: Mapping[str, str] = os.environ) -> Path:
    # AUM_LAUNCH_AGENTS_DIR：安裝測試用，指到暫存資料夾（在這台 Mac 上測試時不看真的 ~/Library/LaunchAgents）
    custom = environ.get("AUM_LAUNCH_AGENTS_DIR")
    return Path(custom) if custom else Path.home() / "Library" / "LaunchAgents"


def legacy_job_loaded() -> bool:
    """launchd 裡還有 install-launchd.sh 的工作（plist 已移走但還沒停止、或還沒登出）。無法確認時當成還在"""
    if sys.platform != "darwin":
        return False
    try:
        proc = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LEGACY_LABEL}"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return True
    return proc.returncode == 0


def legacy_agent_installed(environ: Mapping[str, str] = os.environ,
                           job_loaded: Callable[[], bool] | None = None) -> bool:
    """舊的收集器在：plist 還在，或 launchd 裡還有它的工作（與 App 的 CollectorService.legacyInstalled 相同，Fable F-02）。
    AUM_LAUNCH_AGENTS_DIR（安裝測試）有值時只看那個資料夾，不問真的 launchd"""
    if (launch_agents_dir(environ) / f"{LEGACY_LABEL}.plist").exists():
        return True
    if job_loaded is None:
        if environ.get("AUM_LAUNCH_AGENTS_DIR"):
            return False
        job_loaded = legacy_job_loaded
    return job_loaded()


def app_agent_log_path(environ: Mapping[str, str] = os.environ) -> Path:
    """App 內建的收集器自己寫日誌（LaunchAgent 的 plist 在 App 內，不能寫 ~ 開頭的路徑）：
    與舊安裝同一個檔案；`AI_USAGE_MONITOR_HOME` 有值（測試）時寫在那個資料夾裡"""
    if environ.get("AI_USAGE_MONITOR_HOME"):
        return paths.APP_SUPPORT_DIR / "logs" / "collector.log"
    return Path.home() / "Library" / "Logs" / "AIUsageMonitor" / "collector.log"


def redirect_stderr_to(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(fd, sys.stderr.fileno())
    os.close(fd)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="收集 Claude 與 Codex 的用量")
    parser.add_argument("--compact", action="store_true", help="輸出單行 JSON")
    parser.add_argument("--write-local", action="store_true", help="寫入本機 usage.json")
    parser.add_argument("--upload", action="store_true", help="上傳到中繼 API（未設定時略過）")
    parser.add_argument("--quiet", action="store_true", help="不在 stdout 輸出 JSON")
    parser.add_argument("--agent", choices=["app"], help="由 App 內建的 LaunchAgent 執行（ADR-0013）：自己寫日誌，"
                        "install-launchd.sh 的收集器存在時不執行")
    parser.add_argument("--tokens-only", action="store_true",
                        help="只統計本機 Token，不收集額度（Windows 排程的預設，ADR-0011 第 2 節）")
    parser.add_argument("--log-file", help="日誌附加到這個檔案（Windows 的 pythonw 沒有 stderr）")
    args = parser.parse_args(argv)
    if args.log_file:
        sys.stderr = open(args.log_file, "a", encoding="utf-8", buffering=1)  # 用到程序結束

    if args.tokens_only:
        # 不執行 claude／codex、不寫 usage.json、不上傳：只有 Token 統計（本機）。
        # 這是唯一的工作，失敗時回傳非 0，工作排程器的「上次執行結果」才看得出來
        ok = token_stats.run_safely()
        history.tidy_safely()  # 保留期間的清理（收集額度時由 history.record 執行）
        return 0 if ok else 1

    if args.agent == "app":
        redirect_stderr_to(app_agent_log_path())
        if legacy_agent_installed():
            log("偵測到 install-launchd.sh 安裝的收集器，App 內建的收集器不執行（到 App 的設定按「改用內建收集器」遷移）")
            return 0

    snapshot = collect()
    if not snapshot["providers"]:
        fix = "重新打開 App（會重新偵測）" if args.agent == "app" else "重新執行 scripts/install-launchd.sh"
        log(f"config.json 的 enabled_providers 沒有啟用任何服務，登入 Claude Code 或 Codex CLI 後{fix}")
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
