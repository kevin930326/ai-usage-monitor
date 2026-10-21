#!/bin/bash
# 偵測這台 Mac 登入過哪些服務，每行印出一個結果（順序與收集器相同）：
#   claude／codex      已登入，要啟用
#   ?claude／?codex    不知道（找不到執行檔、或輸出認不得）：安裝腳本不更動 enabled_providers
#   （不印）           沒有登入
#
#   detect-providers.sh [claude 執行檔路徑] [codex 執行檔路徑]
#
# 兩者都問服務自己的 CLI，不讀取任何登入資訊的內容（ADR-0006、ADR-0007）；輸出可能含 email，一律丟棄。
# Claude：`claude auth status` 登入時結束碼為 0。
# Codex：`codex login status` 用 ChatGPT 登入時結束碼 0，未登入時結束碼 1 並印出「Not logged in」。
#   用 API key 登入沒有訂閱額度，不啟用。找不到 codex 時，Codex 的資料夾存在才算「不知道」
#   （裝過但這次找不到），否則就是沒用過 Codex。
set -euo pipefail

CLAUDE="${1:-}"
CODEX="${2:-}"
cd "${TMPDIR:-/tmp}"

if [ -z "$CLAUDE" ]; then
    echo '?claude'
elif "$CLAUDE" auth status --json </dev/null >/dev/null 2>&1; then
    echo claude
fi

if [ -z "$CODEX" ]; then
    if [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then echo '?codex'; fi
else
    CODEX_RC=0
    CODEX_STATUS="$("$CODEX" login status </dev/null 2>&1)" || CODEX_RC=$?
    case "$CODEX_RC:$CODEX_STATUS" in
        0:*ChatGPT*) echo codex ;;
        0:*"API key"*) ;;
        1:*"Not logged in"*) ;;
        *) echo '?codex' ;;
    esac
fi
