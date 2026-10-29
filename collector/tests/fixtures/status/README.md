# 狀態頁 fixture

| 檔案 | 來源 | 用途 |
|---|---|---|
| `openai-incidents.json` | **手寫**（2026-10-29），依 `https://status.openai.com/api/v2/incidents.json`（incident.io 的 Statuspage 相容格式）：26 字的 ULID 形狀 ID、`components` 為空陣列（OpenAI 的事故沒有元件資訊）、`page_id`、`updated_at` 等欄位 | `test_service_status.py` 的 `test_chatgpt_only_incidents_do_not_count_for_codex`：名稱只寫 ChatGPT 的事故不算 Codex，同時提到 Codex 或 API 的仍然算（ADR-0018 第 4 節） |

沒有任何真實帳號或使用者資料；事故名稱是虛構的。
