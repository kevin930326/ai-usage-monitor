# 需求規格

## 1. 目的

讓同時使用 Claude 與 Codex 的開發者，不用打開電腦就能在 iPhone 鎖定畫面掌握剩餘額度，避免工作到一半被限流。

## 2. 範圍

**包含**
- Claude：5 小時視窗、每週視窗的使用率與重置時間
- Codex：每週視窗（及有提供的其他視窗）的使用率與重置時間
- iPhone 鎖定畫面／動態島的 Live Activity 顯示
- 手動更新按鈕、捷徑定時重開

**不包含**
- Android、主畫面小工具（可列為未來擴充）
- 多使用者、帳號系統、多帳號切換
- Claude 與 Codex 以外的服務（provider 架構保留擴充空間）
- APNs 遠端推播（需付費帳號，列為未來擴充）

## 3. 功能需求

| ID | 需求 | 優先度 |
|---|---|---|
| FR-1 | 收集器能讀取 Claude Code 登入資訊並取得 Claude 用量 | Must |
| FR-2 | 收集器能讀取 Codex CLI 登入資訊並取得 Codex 用量 | Must |
| FR-3 | 收集器輸出統一格式的 JSON（見架構文件） | Must |
| FR-4 | 收集器每 5 分鐘自動執行（launchd） | Must |
| FR-5 | 收集器將結果上傳至中繼 API | Must |
| FR-6 | 中繼 API 保存最新一筆資料並提供讀取 | Must |
| FR-7 | iOS App 可設定中繼 API 網址與讀取密鑰 | Must |
| FR-8 | Live Activity 顯示兩家服務各視窗的使用率、進度條、重置倒數 | Must |
| FR-9 | Live Activity 上的「更新」按鈕可在不開 App 的情況下更新數字 | Must |
| FR-10 | 提供捷徑動作「重新啟動用量監看」，結束舊卡片並開新卡片 | Must |
| FR-11 | 顯示資料最後更新時間，過期資料以灰色呈現 | Should |
| FR-12 | 單一服務失敗時，另一服務照常顯示 | Should |

### 3.1 參考相關專案新增的需求

來源與取捨見 [相關專案調查](04-related-work.md)。

| ID | 需求 | 優先度 | 里程碑 |
|---|---|---|---|
| FR-13 | 輸出 JSON 帶有 `schema_version`，iOS 端依版本解析 | Must | v0.2 |
| FR-14 | 收集各模型的每週額度（如 Opus），預設不顯示 | Could | v0.2 |
| FR-15 | Live Activity 將所有額度中剩餘最少的一項放在最顯眼位置（含動態島） | Should | v0.4 |
| FR-16 | 依剩餘比例上色：> 50% 綠、20–50% 黃、< 20% 紅 | Should | v0.4 |
| FR-17 | 可切換顯示「已用 %」或「剩餘 %」 | Could | v0.4 |
| FR-18 | 依近期用量預測用完時間，只在早於重置時間時顯示 | Could | v1.1 |
| FR-19 | 額度低於門檻或重置恢復時通知，同一事件只通知一次 | Could | v1.1 |

## 4. 非功能需求

| ID | 需求 |
|---|---|
| NFR-1 安全 | OAuth token 不得離開 Mac；repo 內不得含任何密鑰 |
| NFR-2 安全 | 中繼 API 讀寫使用不同密鑰 |
| NFR-3 成本 | 全部使用免費方案（免費 Apple ID、Cloudflare 免費額度） |
| NFR-4 相容 | iOS 17 以上（互動式 Live Activity 需要） |
| NFR-5 維護 | 每家服務為獨立 provider，API 變動只需修改單一模組 |
| NFR-6 透明 | README 提供隱私與安全章節，列出所有上傳的資料與網路請求 |

## 5. 已知限制

- Live Activity 最長約 8 小時後由系統結束 → 以捷徑定時重開處理。
- 免費 Apple ID 簽署的 App 7 天後需重新安裝。
- 用量 API 為非公開介面，可能隨時變更。
