# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號採 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Added
- ADR-0004（提議中）：用量歷史資料的存放方式，比較本機檔案、中繼保存多筆與兩者並用，列出待決定問題（#23）
- iOS Live Activity：鎖定畫面與動態島顯示各服務各額度、最吃緊的一項、重置倒數與更新時間；依剩餘比例上色；過期資料轉灰；單一服務失敗不影響另一服務（FR-8, FR-11, FR-12, FR-15, FR-16）
- Live Activity 上的「更新」按鈕，不開 App 即可更新（FR-9）
- 重置時間已過的額度顯示「已重置」（FR-26）；可切換顯示已用或剩餘 %（FR-17）
- Apple Watch 智慧型堆疊用的精簡版面（尚未啟用，需 iOS 18，FR-27）
- UsageKit：`UsageActivityState`（Live Activity 狀態，限制在 4KB 內）、依時間判斷重置的百分比與顯示模式
- iOS Debug 示範模式 `AUM_DEMO`，以假資料截圖

## [0.3.0] - 2026-10-21

### Added
- Mac 離線處理：需求 FR-26（重置後顯示「已重置」）、已知限制、讓 Mac 保持清醒的說明（#15）
- ADR-0003（提議中）：雲端排程收集，列出決定前需驗證的問題（#15）
- Apple Watch 規劃：需求 FR-27 ~ FR-30，v0.4 加入手錶版 Live Activity，新增里程碑 v1.4（#17）
- UsageKit 共用 Swift Package：資料模型、`schema_version` 檢查、最吃緊額度、顏色分級、`RelayClient`、`UsageWindowRow`；CI 新增 `swift test`（#12, #14）
- iOS App 主畫面與設定：顯示各服務剩餘額度與重置倒數、最吃緊額度、資料過期提示，讀取密鑰存於 Keychain（#13）

### Changed
- CI：同一個 PR 有新 push 時自動取消舊的 run（#20）
- CI：UsageKit 測試改在 Linux 的 `swift:6.2` 容器執行，避免 macOS runner 容量不足被取消（#14）

## [0.2.0] - 2026-10-21

### Added
- Cloudflare Worker 中繼 API：讀寫分離密鑰、常數時間比對、內容驗證（#7, #10）
- 收集器輸出 `schema_version`，並以 `hidden` 列出 Claude 各模型每週額度（#6, #9）
- 收集器 `--write-local` 原子寫入本機 `usage.json`，`--upload` 上傳中繼，寫入密鑰存於 Keychain（#6, #9）
- launchd 排程範本與安裝／移除腳本，每 5 分鐘自動執行（#6, #9）
- GitHub Actions CI：Python 3.10 ~ 3.13 與 Worker 測試（#5, #8）
- 相關專案調查文件，需求規格新增 FR-13 ~ FR-19、NFR-6（#3, #4）
- Mac 選單列 App 規劃：需求 FR-20 ~ FR-25、NFR-7、NFR-8，架構新增 UsageKit 共用套件，里程碑新增 v1.1 ~ v1.3（#3, #4）

### Fixed
- Worker 測試指令改用檔名模式，相容 Node 24（#10）

## [0.1.0] - 2026-10-21

### Added
- Mac 收集器：Claude 與 Codex provider，輸出統一格式 JSON（#1, #2）
- 需求規格、系統架構、開發流程文件
- ADR-0001 中繼方案、ADR-0002 Live Activity 重開策略

[Unreleased]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kevin930326/ai-usage-monitor/releases/tag/v0.1.0
