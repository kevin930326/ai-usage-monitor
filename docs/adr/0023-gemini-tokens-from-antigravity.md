# ADR-0023：Gemini 的 Token 統計讀 Antigravity 的對話資料庫

- 狀態：**已採用**
- 日期：2026-11-25
- 相關需求：FR-43、FR-44（Token 統計）、FR-49（第二層同步）、NFR-9（統計只存數字）
- 相關：[ADR-0009](0009-local-history-and-token-stats.md)（Claude、Codex 的 Token 統計）、[ADR-0022](0022-gemini-usage-via-antigravity.md)（Gemini 額度）

## 背景

ADR-0022 加了 Gemini（Antigravity）的額度，但 Token 統計卡片只有 Claude 與 Codex：統計來自本機的對話紀錄，而 Antigravity 的紀錄格式不同。

## 調查（2026-11-25，Antigravity 2.33.0）

- 每個對話一個 SQLite 資料庫：`~/.gemini/antigravity/conversations/<uuid>.db`（WAL 模式，旁邊有 `-wal`、`-shm`）。
- `gen_metadata`（`idx`、`data`）每次模型生成一列；`data` 是 protobuf，欄位 1 的子欄位：
  - 4：用量（Antigravity 的 `ModelUsageStats`）：2 input、3 output（含思考）、4 cache_write、5 cache_read、9 思考、10 回答（3 ＝ 9 ＋ 10）、11 回應 ID。17.2 是同一份的鏡像。
  - 19：模型名稱（例：`gemini-4-neon`；用 Claude／GPT 時是那個模型的名稱）。
  - 20：鍵值對，其中 `last_step_index` 是這次生成對應的步驟。
- `steps.metadata` 的欄位 1.1 是步驟建立的時間（epoch 秒）。
- 實測 262 個對話、870 列：859 列有用量，11 列是失敗的生成（沒有用量）；回應 ID 沒有重複；時間都對得上。input 不含 cache_read（input 比 cache_read 小），與 Claude 的定義相同。

## 決定

1. **只在 `enabled_providers` 列出 gemini 時讀**（ADR-0022 的安裝腳本偵測到 Antigravity 才會列出）。
2. 以 `mode=ro` 唯讀開啟（不用 `immutable`：新內容在 `-wal`，immutable 會讀不到）；忙碌時最多等 1 秒，打不開、不是 SQLite 或還在建立的檔案這次略過，不影響其他檔案。檔名不是 `<uuid>.db` 的不讀。
3. 只讀 `gen_metadata.data` 的欄位 1.4（數字）、1.19（模型名稱，套用與其他服務相同的白名單，新增 `gemini-` 開頭）、1.20 的 `last_step_index`，以及對應 `steps.metadata` 的 1.1（時間）。`data` 其他欄位與 `steps` 的內容不解析、不保存。
4. Token 向量：input＝1.4.2、cache_write＝1.4.4、cache_read＝1.4.5、output＝1.4.3、reasoning＝1.4.9（推理是 output 的子集，同 Codex）。
5. 去重 ID 是 `<對話 uuid>:<idx>`；進度記在 `scan_state.state` 的 `idx`。每次從上次最後一筆重讀（那筆可能上次讀到時還沒寫完），以 `seen_ids` 的差額補上。改變偵測用主檔加 `-wal` 的大小與時間。
6. 服務是 `gemini`（訂閱與額度是 Antigravity 的）；在 Antigravity 裡用 Claude／GPT 模型的生成也算在 gemini 之下，模型欄位照實記錄。
7. **不計任務時間**：Antigravity 沒有 Claude、Codex 那樣明確的「一次提示到完成」的紀錄，Gemini 的最長任務不顯示。
8. 第二層：中繼的白名單加入 `gemini`。已部署的舊中繼會以 422 拒絕整批，所以收集器把 Gemini 的列排在最後、單獨成批；被 422 拒絕時記下 `meta.gemini_upload_after`，一天後再試，Claude 與 Codex 照常同步。

## 後果

- 統計卡片多一個 Gemini 分頁（只有一個服務有資料時不顯示切換列，與原本相同）。
- Antigravity 改了資料庫格式時，解析失敗的列計入「無法解析」，和其他服務一樣由格式偵測（ADR-0009 第 9 節）提醒。
- 中繼要重新部署（`npx wrangler deploy`）才會收 Gemini 的列。
