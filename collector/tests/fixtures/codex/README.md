# Codex app-server fixture

收集器的 Codex provider 透過 `codex app-server --listen stdio://` 的 `account/rateLimits/read` 取得額度（ADR-0007）。

| 檔案 | 來源 | 情境 |
|---|---|---|
| `rate-limits-team.json` | 2026-10-22 Codex CLI 0.163.0-alpha.10.2 實際回應的 `result` | Team 方案、5 小時與每週額度 |
| `logged-out-error.json` | 同版本，`CODEX_HOME` 指向空資料夾時的實際 `error` | 未登入 |
| `initialize.json` | 同版本 `initialize` 的實際 `result` | 握手 |
| `notification.json` | 同版本 `initialize` 後主動送出的通知 | 收集器要略過的通知 |

實際回應已遮蔽：`accountId`、`installationId` 改為 0，主機名稱與路徑改為假資料。
