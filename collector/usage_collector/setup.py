"""App 內建收集器的設定（ADR-0013 第 3 節）：找 claude／codex 的完整路徑、問它們自己的 CLI 是否登入，
寫進 config.json。規則與 `scripts/install-launchd.sh`＋`scripts/detect-providers.sh` 相同：

- 找到的執行檔路徑寫進 `claude_path`／`codex_path`（LaunchAgent 的 PATH 只有系統目錄）
- `claude_config_dir`／`codex_home` 有對應的環境變數時寫入，沒有時保留原本的值
- 至少一個服務已登入、而且沒有任何「不知道」時才寫 `enabled_providers`；否則不更動
- 只執行 `claude auth status --json` 與 `codex login status` 看結束碼與登入方式，輸出（可能含 email）一律丟棄，
  不讀任何登入資訊的內容（ADR-0006、ADR-0007）

用法：python3 -m usage_collector.setup [--json] [--dry-run]

`--json` 只印出各服務的狀態（`enabled`、`not_logged_in`、`api_key`、`not_installed`、`unknown`）與是否找到執行檔，
不印路徑；給 App 的設定精靈顯示「已登入／需要處理」用（FR-54）。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Mapping
from pathlib import Path

from . import paths

TIMEOUT = 20  # 秒，與 detect-providers.sh 相同

# 與 install-launchd.sh 的候選位置相同，另外加上 GUI App 的 PATH 找不到、但常見的 Node 版本管理工具
CLAUDE_CANDIDATES = ("~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "~/.npm-global/bin/claude", "~/.bun/bin/claude", "~/.volta/bin/claude",
                     "~/.nvm/versions/node/*/bin/claude")
CODEX_CANDIDATES = ("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "~/.local/bin/codex",
                    "~/.npm-global/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.bun/bin/codex",
                    "~/.volta/bin/codex", "~/.nvm/versions/node/*/bin/codex")


def expand_home(path: str, environ: Mapping[str, str]) -> str:
    """`~` 換成 environ 的 HOME（測試以暫存資料夾當 HOME，不會找到這台電腦真的 claude）"""
    if path == "~" or path.startswith("~/"):
        return environ.get("HOME", str(Path.home())) + path[1:]
    return path


def find_executable(name: str, candidates: Iterable[str], environ: Mapping[str, str] = os.environ,
                    preferred: object = None) -> str | None:
    """`preferred`（config.json 裡原本的路徑）還能執行就用它，再找 PATH，最後依序找候選位置
    （`~` 展開、`*` 取版本最新的那個）。回傳絕對路徑或 None。"""
    if isinstance(preferred, str) and preferred and os.path.isfile(preferred) and os.access(preferred, os.X_OK):
        return os.path.abspath(preferred)
    found = shutil.which(name, path=environ.get("PATH"))
    if found:
        return os.path.abspath(found)
    for pattern in candidates:
        expanded = expand_home(pattern, environ)
        matches = sorted(glob.glob(expanded), reverse=True) if "*" in expanded else [expanded]
        for candidate in matches:
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return os.path.abspath(candidate)
    return None


def child_env(path: str, environ: Mapping[str, str]) -> dict[str, str]:
    """執行偵測用的環境：以 `environ` 為準（CLAUDE_CONFIG_DIR／CODEX_HOME 跟著傳下去），PATH 前面加上執行檔所在的資料夾。
    npm／nvm 裝的 claude、codex 是 `#!/usr/bin/env node` 腳本，App 與 launchd 的 PATH 只有系統目錄，
    node 通常和它們在同一個資料夾（與 providers/codex.py 相同的做法）。"""
    path_dirs = (os.path.dirname(path), environ.get("PATH"), "/usr/bin:/bin")
    return {**environ, "PATH": os.pathsep.join(filter(None, path_dirs))}


def run_limited(argv: list[str], env: Mapping[str, str] | None = None, timeout: float | None = None) -> tuple[int, str]:
    """在自己的 process group 執行，逾時（預設 `TIMEOUT` 秒）就結束整組（回傳 124）。stdin 關閉、在暫存資料夾執行。"""
    timeout = TIMEOUT if timeout is None else timeout
    with tempfile.TemporaryDirectory(prefix="aum-setup-") as cwd:
        try:
            proc = subprocess.Popen(argv, cwd=cwd, env=None if env is None else dict(env), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError:
            return 127, ""
        try:
            out, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            proc.communicate()
            return 124, ""
        return proc.returncode, out.decode("utf-8", "replace")


def detect_claude(path: str | None, environ: Mapping[str, str] = os.environ) -> str:
    if path is None:
        config_dir = environ.get("CLAUDE_CONFIG_DIR") or expand_home("~/.claude", environ)
        return "unknown" if os.path.isdir(config_dir) else "not_installed"
    rc, _ = run_limited([path, "auth", "status", "--json"], child_env(path, environ))
    return {0: "enabled", 1: "not_logged_in"}.get(rc, "unknown")


def detect_codex(path: str | None, environ: Mapping[str, str] = os.environ) -> str:
    if path is None:
        home = environ.get("CODEX_HOME") or expand_home("~/.codex", environ)
        return "unknown" if os.path.isdir(home) else "not_installed"
    rc, out = run_limited([path, "login", "status"], child_env(path, environ))
    # 先比對「沒有訂閱額度」的 API key 登入，避免說明文字剛好提到 ChatGPT
    if rc == 0 and "API key" in out:
        return "api_key"
    if rc == 1 and "Not logged in" in out:
        return "not_logged_in"
    if rc == 0 and out.startswith("Logged in using ChatGPT"):
        return "enabled"
    return "unknown"


def plan(states: Mapping[str, str]) -> list[str] | None:
    """要寫入的 enabled_providers；None＝不更動（沒有任何已登入，或有任何一個不知道）。"""
    if any(state == "unknown" for state in states.values()):
        return None
    enabled = [name for name in ("claude", "codex") if states.get(name) == "enabled"]
    return enabled or None


def read_config(path: Path) -> dict:
    """沒有檔案時是空的；不是 JSON 物件時丟出 ValueError（不覆寫使用者的檔案）"""
    try:
        config = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    if not isinstance(config, dict):
        raise ValueError(f"{path.name} 不是 JSON 物件，沒有寫入")
    return config


def write_config(path: Path, updates: Mapping[str, object]) -> None:
    """合併寫入（保留 relay_url 等其他欄位），先寫暫存檔再改名；檔案不是 JSON 物件時不寫。"""
    config = read_config(path)
    config.update(updates)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".config-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def run(config_path: Path, environ: Mapping[str, str] = os.environ, dry_run: bool = False,
        candidates: Mapping[str, Iterable[str]] | None = None) -> dict:
    """`candidates`：測試用，取代預設的候選位置（{"claude": […], "codex": […]}）"""
    candidates = candidates or {"claude": CLAUDE_CANDIDATES, "codex": CODEX_CANDIDATES}
    # 以現有設定為準偵測：原本可用的路徑與自訂資料夾（install-launchd.sh 寫的）在 App 的環境裡也照樣使用，
    # 不會因為 App 沒有 shell 的環境變數就把原本啟用的服務判斷成沒安裝
    config = read_config(config_path)
    detect_env = dict(environ)
    for key, env in (("claude_config_dir", "CLAUDE_CONFIG_DIR"), ("codex_home", "CODEX_HOME")):
        if not detect_env.get(env) and isinstance(config.get(key), str) and config[key]:
            detect_env[env] = config[key]
    claude = find_executable("claude", candidates["claude"], detect_env, config.get("claude_path"))
    codex = find_executable("codex", candidates["codex"], detect_env, config.get("codex_path"))
    states = {"claude": detect_claude(claude, detect_env), "codex": detect_codex(codex, detect_env)}
    enabled = plan(states)
    updates: dict[str, object] = {}
    # App 從登入項目啟動時沒有這兩個環境變數：沒有時保留 config.json 原本的值（遷移前 install-launchd.sh 寫的）
    for key, env in (("claude_config_dir", "CLAUDE_CONFIG_DIR"), ("codex_home", "CODEX_HOME")):
        if environ.get(env):
            updates[key] = environ[env]
    if claude:
        updates["claude_path"] = claude
    if codex:
        updates["codex_path"] = codex
    if enabled is not None:
        updates["enabled_providers"] = enabled
    if not dry_run:
        write_config(config_path, updates)
    return {
        "claude": {"state": states["claude"], "found": claude is not None},
        "codex": {"state": states["codex"], "found": codex is not None},
        "enabled_providers": enabled,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="設定 App 內建的收集器（找 claude／codex、偵測登入狀態）")
    parser.add_argument("--json", action="store_true", help="以 JSON 印出結果（不含路徑）")
    parser.add_argument("--dry-run", action="store_true", help="只偵測，不寫 config.json")
    args = parser.parse_args(argv)
    try:
        result = run(paths.CONFIG_PATH, dry_run=args.dry_run)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"無法寫入設定：{type(e).__name__}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        labels = {"enabled": "已登入", "not_logged_in": "沒有登入", "api_key": "以 API key 登入（沒有訂閱額度，不啟用）",
                  "not_installed": "沒有安裝", "unknown": "不確定"}
        for name in ("claude", "codex"):
            print(f"{name}：{labels[result[name]['state']]}")
        if result["enabled_providers"] is None:
            print("enabled_providers 維持原設定")
    return 0


if __name__ == "__main__":
    sys.exit(main())
