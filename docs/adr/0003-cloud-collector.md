# ADR-0003：雲端排程收集（不依賴 Mac）

- 狀態：**提議中**（待驗證後決定）
- 日期：2026-10-21

## 背景

目前用量由 Mac 上的收集器取得（[ADR-0001](0001-cloudflare-worker-relay.md)）。Mac 關機或睡眠時就停止更新，手機只能顯示最後一筆資料。此外，Mac 離線期間在手機或網頁上使用 claude.ai 也會消耗同一份額度，卻無法反映。

已採用的緩解措施（讓 Mac 插電時不睡眠、重置後顯示「已重置」，見 FR-26）能涵蓋大部分日常情況，但無法讓手機在 Mac 離線時仍顯示最新數字。

## 考慮中的選項

| 選項 | 說明 | 優點 | 缺點 |
|---|---|---|---|
| A. 維持現狀 | 只由 Mac 收集 | token 不離開 Mac；已可運作 | Mac 離線時資料停滯 |
| **B. Worker 排程收集** | Worker 以 Cron Trigger 每 5 分鐘自行查詢用量，使用**另外登入的獨立 session** | 完全不依賴 Mac；免費；沿用現有 Worker | token 存放於雲端；需自行刷新 token；依賴更多非公開介面 |
| C. 常開裝置收集 | 在樹莓派等常開裝置另外登入並執行現有收集器 | 程式不需修改；token 留在自己的裝置 | 需要額外硬體與維護 |
| D. iPhone 直接查詢 | App 內嵌網頁登入 claude.ai / ChatGPT 後自行查詢 | 不需要 Mac 與雲端收集 | 網站防機器人保護、session 定期失效、iOS 背景網路限制；最不穩定 |

D 因穩定性問題不列入優先評估。

## 選項 B 的設計草案

```
Cron（每 5 分鐘）→ Worker
  ├─ 從 KV 讀取加密的 token → 以 Secret 中的金鑰解密
  ├─ token 將過期 → 刷新 → 新 token 加密後寫回 KV
  ├─ 查詢 Claude / Codex 用量 → 組成與收集器相同的快照（schema_version 1）
  └─ 寫入 KV latest（iPhone 讀取方式不變）
```

- 雲端使用**獨立登入**取得的 token，與 Mac 的 Claude Code / Codex CLI 互不影響。
- token 於 KV 中以 AES-GCM 加密，金鑰存在 Worker Secret；Worker Secret 本身無法於執行時更新，因此會輪替的 refresh token 必須放在 KV。
- Mac 收集器可保留為備援，兩邊同時上傳時以較新的 `updated_at` 為準。

## 決定前需驗證的問題

| # | 問題 | 驗證方式 | 不通過時 |
|---|---|---|---|
| Q1 | Claude：另外登入的 session（例如另一台機器的 `claude /login`，或 `claude setup-token` 的長效 token）是否有權限呼叫用量端點？ | 以各種 token 呼叫用量端點，記錄回應 | 若無可用 token，B 不成立 |
| Q2 | Claude：能否在 Claude Code 之外刷新 token？refresh token 是否會輪替？有效期多久？刷新一個 session 是否影響其他 session？ | 在測試帳號 session 上手動刷新並觀察 Mac 端是否仍正常 | 若會影響 Mac 端，B 不成立 |
| Q3 | Codex：另一裝置的 `codex login` 是否會讓 Mac 的 session 失效？ChatGPT token 的刷新與輪替規則？ | 兩台裝置同時登入並交替查詢 | 同 Q2 |
| Q4 | 從 Cloudflare Workers 的網路發出請求，是否會被 Anthropic / OpenAI 的防機器人機制阻擋？ | 部署最小 Worker 呼叫兩個用量端點 | 改評估選項 C |
| Q5 | 雲端代為刷新 token 是否符合兩家服務的使用條款？帳號是否有被停用的風險？ | 閱讀服務條款與相關說明 | 不採用 B |
| Q6 | 免費額度是否足夠？（Cron 次數、KV 寫入：快照 288 次／日 + token 輪替） | 依實測的輪替頻率試算 | 降低頻率或改選項 C |
| Q7 | 加密金鑰與 token 的威脅模型：Cloudflare 帳號被盜時的影響範圍與撤銷流程 | 撰寫威脅模型與撤銷步驟 | 補強後再決定 |

## 決策準則

- Q1～Q4 全部通過，且 Q5 確認無違反條款 → 採用 B，修訂 NFR-1 為「token 只存放於使用者控制的環境，雲端端以加密保存」。
- Q4 不通過但其餘通過 → 考慮 C。
- 其他情況 → 維持 A。

## 影響（若採用 B）

- 需新增 ADR 修訂 NFR-1，並更新 README 的隱私與安全章節（NFR-6）。
- Worker 新增排程與 token 管理模組，以及對應的測試。
- 收集器改為可選的備援。
