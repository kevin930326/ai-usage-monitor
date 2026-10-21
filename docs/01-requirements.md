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
- Android、iPhone 主畫面小工具（可列為未來擴充）
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
| FR-11 | 顯示資料最後更新時間，過期資料以灰色呈現。過期門檻：iPhone、Mac 與 Live Activity 為 30 分鐘；手錶 App 與錶面複雜功能為 45 分鐘，因為手錶約每 30 分鐘才背景更新一次，且實際時間由 watchOS 決定、常會延後，門檻若與間隔相同，稍有延後就會轉灰 | Should |
| FR-12 | 單一服務失敗時，另一服務照常顯示 | Should |

### 3.1 參考相關專案新增的需求

來源與取捨見 [相關專案調查](04-related-work.md)。

| ID | 需求 | 優先度 | 里程碑 |
|---|---|---|---|
| FR-13 | 輸出 JSON 帶有 `schema_version`，iOS 端依版本解析 | Must | v0.2 |
| FR-14 | 收集各模型的每週額度（如 Opus），預設不顯示 | Could | v0.2 |
| FR-15 | Live Activity 將所有額度中剩餘最少的一項放在最顯眼位置（含動態島） | Should | v0.4 |
| FR-16 | 進度條使用服務識別色（Claude 珊瑚橘、Codex 青綠，淺色與深色外觀各自調整）；剩餘 < 20% 改為紅色；資料過期轉灰。百分比等文字一律 primary，不以顏色表示狀態，文字對比度至少 4.5:1（WCAG AA）。動態島精簡版與圓形錶面複雜功能以原創服務圖示（Claude 八芒星、Codex 六瓣雲）與識別色區分，不使用官方 logo | Should | v0.4 |
| FR-17 | 可切換顯示「已用 %」或「剩餘 %」 | Could | v0.4 |
| FR-18 | 依近期用量預測用完時間，只在早於重置時間時顯示 | Could | v1.1 |
| FR-19 | 額度低於門檻或重置恢復時通知，同一事件只通知一次 | Could | v1.1 |

FR-18、FR-19、FR-23 所需的歷史資料存放方式評估中，見 [ADR-0004](adr/0004-usage-history.md)。

### 3.2 Mac 選單列 App

| ID | 需求 | 優先度 | 里程碑 |
|---|---|---|---|
| FR-20 | 收集器同時把結果寫入本機 `usage.json` | Should | v0.2 |
| FR-21 | 選單列圖示顯示最吃緊額度的 % 與顏色 | Could | v1.2 |
| FR-22 | 點開面板顯示所有額度、進度條、重置倒數、更新時間 | Could | v1.2 |
| FR-23 | 面板顯示近期用量趨勢圖 | Could | v1.2 |
| FR-24 | 提供 Mac 桌面小工具 | Could | v1.2 |
| FR-25 | 面板加入動態或 3D 視覺效果，只在面板開啟時執行 | Could | v1.3 |

### 3.3 Mac 離線時的處理

| ID | 需求 | 優先度 | 里程碑 |
|---|---|---|---|
| FR-26 | 額度的重置時間已過時，標示「已重置」並以 0% 顯示，不再顯示舊的百分比 | Should | v0.4 |

完全不依賴 Mac 的雲端收集方案仍在評估中，見 [ADR-0003](adr/0003-cloud-collector.md)。

### 3.4 Apple Watch

| ID | 需求 | 優先度 | 里程碑 |
|---|---|---|---|
| FR-27 | iPhone 的 Live Activity 出現在 Apple Watch 智慧型堆疊，提供手錶專用的精簡版面，顯示最吃緊的額度 | Should | v0.4 |
| FR-28 | 錶面複雜功能：顯示最吃緊額度的剩餘 % 與服務標示，顏色依 FR-16（圓形、矩形、單行三種尺寸） | Could | v1.4 |
| FR-29 | 手錶 App：列出所有服務的可見額度與重置倒數 | Could | v1.4 |
| FR-30 | 手錶從 iPhone 取得中繼網址與讀取密鑰（WatchConnectivity），不需在手錶上輸入 | Could | v1.4 |

## 4. 非功能需求

| ID | 需求 |
|---|---|
| NFR-1 安全 | OAuth token 不得離開 Mac；repo 內不得含任何密鑰 |
| NFR-2 安全 | 中繼 API 讀寫使用不同密鑰 |
| NFR-3 成本 | 全部使用免費方案（免費 Apple ID、Cloudflare 免費額度） |
| NFR-4 相容 | iOS 17 以上（互動式 Live Activity 需要）；watchOS 11 以上（Live Activity 顯示於手錶需要） |
| NFR-5 維護 | 每家服務為獨立 provider，API 變動只需修改單一模組 |
| NFR-6 透明 | README 提供隱私與安全章節，列出所有上傳的資料與網路請求 |
| NFR-7 重用 | iOS、watchOS 與 Mac 共用同一個 Swift Package（資料模型、解析、顏色規則） |
| NFR-8 耗能 | Mac App 的動畫只在面板開啟時執行，關閉時不佔 CPU／GPU |

## 5. 已知限制

- Live Activity 最長約 8 小時後由系統結束 → 以捷徑定時重開處理。
- 免費 Apple ID 簽署的 App 7 天後需重新安裝。
- 手錶 App（`apple/WatchApp`）是獨立的 Xcode 專案，沒有嵌入 iOS App，目前只能用 Xcode 直接裝到手錶自用。若要以 TestFlight（或 App Store）散佈，需要先把手錶 App 嵌入 iOS App，一起封存上傳。
- 用量 API 為非公開介面，可能隨時變更。
- **Mac 關機或睡眠時收集器停止更新**，手機只能顯示最後一筆資料。緩解方式：
  - 讓 Mac 插電時不自動睡眠（見[收集器說明](../collector/README.md#讓-mac-保持清醒)）；闔上螢幕仍會睡眠。
  - 重置時間過後改顯示「已重置」（FR-26）。
  - 仍無法反映 Mac 離線期間在手機或網頁上使用 claude.ai 的用量。
