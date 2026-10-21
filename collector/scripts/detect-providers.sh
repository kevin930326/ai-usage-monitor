#!/bin/bash
# 偵測這台 Mac 登入過哪些服務，每行印出一個結果（順序與收集器相同）：
#   claude／codex      已登入，要啟用
#   ?claude／?codex    不知道（找不到執行檔、或輸出認不得）：安裝腳本不更動 enabled_providers
#   （不印）           沒有登入
#
#   detect-providers.sh [claude 執行檔路徑] [codex 執行檔路徑]
#
# 兩者都問服務自己的 CLI，不讀取任何登入資訊的內容（ADR-0006、ADR-0007）；輸出可能含 email，一律丟棄。
# Claude：`claude auth status` 登入時結束碼 0、未登入時 1，其他結束碼視為不知道。
# Codex：`codex login status` 用 ChatGPT 登入時結束碼 0 並印出「Logged in using ChatGPT」，
#   未登入時結束碼 1 並印出「Not logged in」。用 API key 登入沒有訂閱額度，不啟用。
#   找不到 codex 時，Codex 的資料夾存在才算「不知道」（裝過但這次找不到），否則就是沒用過 Codex。
# 兩個指令都限時 TIMEOUT 秒（macOS 沒有 timeout 指令，用 perl 的 alarm），逾時視為不知道。
set -euo pipefail

CLAUDE="${1:-}"
CODEX="${2:-}"
TIMEOUT="${AUM_DETECT_TIMEOUT:-20}"
cd "${TMPDIR:-/tmp}"

# 指令在自己的 process group 執行，逾時時整組結束（只結束外層程序的話，子程序仍握著輸出管線，$(...) 會一直等）
limited() {
    perl -e '
        my $timeout = shift;
        defined(my $pid = fork) or exit 127;
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
        $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 124 };
        alarm $timeout;
        waitpid $pid, 0;
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$TIMEOUT" "$@"
}

if [ -z "$CLAUDE" ]; then
    echo '?claude'
else
    CLAUDE_RC=0
    limited "$CLAUDE" auth status --json </dev/null >/dev/null 2>&1 || CLAUDE_RC=$?
    case "$CLAUDE_RC" in
        0) echo claude ;;
        1) ;;
        *) echo '?claude' ;;
    esac
fi

if [ -z "$CODEX" ]; then
    if [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then echo '?codex'; fi
else
    CODEX_RC=0
    CODEX_STATUS="$(limited "$CODEX" login status </dev/null 2>&1)" || CODEX_RC=$?
    # 先比對「沒有訂閱額度」的情況，避免 API key 的說明文字剛好提到 ChatGPT 而被當成已登入
    case "$CODEX_RC:$CODEX_STATUS" in
        0:*"API key"*) ;;
        1:*"Not logged in"*) ;;
        "0:Logged in using ChatGPT"*) echo codex ;;
        *) echo '?codex' ;;
    esac
fi
