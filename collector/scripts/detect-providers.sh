#!/bin/bash
# 偵測這台 Mac 登入過哪些服務，每行印出一個 provider 名稱（順序與收集器相同）。
#   detect-providers.sh [claude 執行檔路徑]
# Claude：問 Claude Code 自己（`claude auth status` 登入時結束碼為 0），不碰它的 Keychain 項目（ADR-0006）。
# 輸出含 email，一律丟棄。Codex：只檢查 ~/.codex/auth.json 是否存在，不讀取內容。
set -euo pipefail

CLAUDE="${1:-}"
if [ -n "$CLAUDE" ] && (cd "${TMPDIR:-/tmp}" && "$CLAUDE" auth status --json </dev/null >/dev/null 2>&1); then
    echo claude
fi
if [ -f "$HOME/.codex/auth.json" ]; then
    echo codex
fi
