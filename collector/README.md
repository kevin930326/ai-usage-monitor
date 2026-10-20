# collector — Mac 端用量收集器

讀取 Claude Code 與 Codex CLI 在本機的登入資訊，查詢用量並輸出[統一格式的 JSON](../docs/02-architecture.md#3-資料格式)。只使用 Python 標準函式庫。

## 前置條件

| 服務 | 需要 | token 位置 |
|---|---|---|
| Claude | 在終端機執行 `claude` 並 `/login` 過一次（只用 Claude 桌面版不會產生 CLI token） | macOS Keychain `Claude Code-credentials` |
| Codex | 執行 `codex login` 過一次 | `~/.codex/auth.json` |

## 使用

```bash
cd collector
python3 -m usage_collector            # 格式化輸出
python3 -m usage_collector --compact  # 單行輸出
```

第一次讀取 Keychain 時，macOS 可能會詢問是否允許，選「永遠允許」。

結束碼：至少一個服務成功為 `0`，全部失敗為 `1`。

## 測試

```bash
python3 -m unittest -v
```

## 設計重點

- **token 不離開本機**：只輸出百分比與重置時間；錯誤訊息不含例外內容。
- **不自行刷新 token**：避免與 Claude Code / Codex CLI 互搶，過期時提示使用者開一次原程式。
- **provider 互相隔離**：單一服務失敗只會讓該服務的 `error` 有值。
- **新增服務**：在 `usage_collector/providers/` 新增模組並實作 `fetch() -> ProviderUsage`，再到 `providers/__init__.py` 註冊。
