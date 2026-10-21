# Claude Code `/usage` 輸出 fixture

收集器的 Claude provider 解析 `claude -p /usage --safe-mode --no-session-persistence` 的輸出（ADR-0006）。

| 檔案 | 來源 | 情境 |
|---|---|---|
| `usage-max.json`、`usage-max.txt` | 2026-10-21 Claude Code 2.1.306 實際輸出（`--output-format json`／`text`） | Max 方案、三個額度 |
| `logged-out.txt` | 同版本，`CLAUDE_CONFIG_DIR` 指向空資料夾時的實際輸出 | 未登入：只印出成本摘要 |
| `auth-status.json` | 同版本 `claude auth status --json` 的實際欄位 | 取得方案名稱 |
| `partial.txt` | 依 Claude Code 的格式化程式手寫 | 只有每週額度 |
| `overage.txt` | 同上 | 用到超額、跨年（顯示年份）、有分鐘、Sonnet 額度、沒有重置時間 |
| `no-limits.txt` | 同上 | Claude Code 暫時查不到額度 |
| `format-changed.txt` | 手寫 | 格式改變 |

實際輸出已遮蔽：session id 與 uuid 改為 0；「What's contributing」段落列出的 skill、subagent 與 MCP 名稱改為通用名稱；`auth-status.json` 的 email、組織與路徑改為假資料。
