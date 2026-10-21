#!/bin/bash
# 偵測這台 Mac 登入過哪些服務，每行印出一個 provider 名稱（順序與收集器相同）。
# 只檢查登入資訊是否存在，不讀取內容：Keychain 只查項目屬性（不加 -w），不會跳出授權視窗。
set -euo pipefail

if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    echo claude
fi
if [ -f "$HOME/.codex/auth.json" ]; then
    echo codex
fi
