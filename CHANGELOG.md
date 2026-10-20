# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號採 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Added
- Mac 離線處理：需求 FR-26（重置後顯示「已重置」）、已知限制、讓 Mac 保持清醒的說明（#15）
- ADR-0003（提議中）：雲端排程收集，列出決定前需驗證的問題（#15）
- Apple Watch 規劃：需求 FR-27 ~ FR-30，v0.4 加入手錶版 Live Activity，新增里程碑 v1.4（#17）

### Changed
- CI：同一個 PR 有新 push 時自動取消舊的 run（#20）

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

[Unreleased]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kevin930326/ai-usage-monitor/releases/tag/v0.1.0
