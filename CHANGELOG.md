# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號採 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Added
- iPhone 主畫面小工具（小／中／大）與鎖定畫面小工具（圓形／矩形／單行），kind `UsageHomeWidget`，放在既有的 `UsageWidget` 擴充；小工具自己以共用的 Keychain 讀取密鑰呼叫中繼，每 25 分鐘重新整理（資料過期時每小時），重置與過期時間點放在 timeline
- UsageKitUI `ProviderIcon`：原創服務圖示（Claude 八芒星、Codex 六瓣雲鏤空 `>_`），三個平台共用，template 繪製並套服務識別色，附 VoiceOver 名稱
- iOS／watchOS Debug 示範情境 `codex`（Codex 最吃緊）；手錶 `AUM_RENDER` 另輸出圓形複雜功能的淺色與主題色模擬
- 只用 Claude 或只用 Codex 的使用者：收集器 `config.json` 新增 `enabled_providers`，`install-launchd.sh` 依 Mac 上的登入資訊自動偵測並印出結果；未啟用的服務不出現在 `providers`、不算錯誤、不寫日誌。沒有這個欄位時全部啟用（舊安裝不變）
- 各平台在只有一個服務時不留空位（iPhone 大型小工具改放大最吃緊一項、額度單欄），沒有任何服務時顯示「沒有啟用任何服務」提示；Debug 示範情境 `claude-only`、`codex-only`、`none`
- `.claude/skills/ai-usage-monitor-design`：顏色、圖示定義、不收錄官方 logo、過期門檻、不能更改的識別字與 UI 驗證方式

### Changed
- 收集器的 Claude 用量改為執行未修改的 Claude Code（`claude -p /usage`）並解析它的輸出，方案名稱取自 `claude auth status`；收集器不再讀取 Keychain 的 `Claude Code-credentials`、不再持有 token、不再直接呼叫 api.anthropic.com，以符合 Claude Code 的 Legal and compliance 條款。移除 ADR-0005 的委派續期與 `claude-refresh.json`；`/usage` 格式認不得時回報錯誤而不是顯示 0%；安裝腳本改用 `claude auth status` 偵測登入（ADR-0006）
- 手錶取得中繼設定改用 WatchConnectivity `sendMessage`（手錶 App 開啟時向 iPhone 要），不再用 application context，讀取密鑰不會被系統另存一份在 Keychain 以外；舊版留下的 context 會在 iPhone App 啟動時清空。iPhone 改設定後要打開一次手錶 App 才會套用
- Mac：新增 `apple/MacMenuBar/project.team.yml`，以 Team 簽署並為 App 與桌面小工具加入 App Group，不必手改 `project.yml`；預設設定不變（C-06）
- CI：新增 macOS job，產生並建置三個 App（Debug、不簽署），確認擴充有嵌入；不設為必要檢查（C-11）
- 文件：「已用／剩餘」設定（FR-17）明確只用在 iPhone，Mac 與手錶固定顯示剩餘（C-08）；iPhone 主畫面／鎖定畫面小工具列入需求 FR-31、FR-32 與 v0.6 里程碑（C-14）
- iPhone App 與 Widget 擴充加入 App Group 與 Keychain 群組（免費 Apple ID 也可簽署）；中繼網址與顯示模式改存 App Group 的 UserDefaults，第一次啟動時自動從舊位置複製
- 錶面的 `ComplicationView` 移到 UsageKitUI，加入顯示模式與過期門檻參數，iPhone 鎖定畫面小工具共用
- 動態島精簡版與圓形錶面複雜功能的「CL／CX」文字改為服務圖示（FR-16）
- ADR-0003 雲端排程收集：已評估，不採用，見 ADR-0003。`setup-token` 缺少用量端點需要的 `user:profile` 權限，且把訂閱 OAuth token 存在雲端代為續期不符合 Claude Code 的使用條款；維持由 Mac 收集，日後若要 Mac 不必常開改評估常開小裝置（選項 C）。ADR-0004 與需求文件 3.3 節同步更新
- `install-launchd.sh` 偵測 claude 的完整路徑寫進 `config.json`；`set-relay.sh` 改為合併寫入 `config.json`，保留其他設定
- 收集器的 Codex 用量改為執行未修改的 Codex CLI（`codex app-server --listen stdio://` 的 `account/rateLimits/read`）；收集器不再讀取 `~/.codex/auth.json`、不再持有 token、不再直接呼叫 chatgpt.com，至此不讀取任何服務的 token。app-server 每次查完就關閉，逾時或不結束時結束整個 process group；回應中的帳號 ID 不保留；格式認不得時回報錯誤而不是 0%。安裝腳本偵測 codex 路徑寫入 `codex_path`，並改用 `codex login status` 偵測登入，判斷不出來時不更動 `enabled_providers`；找不到 `claude`／`codex` 且沒有 `~/.claude`／`~/.codex` 時視為沒用過、不啟用，只用其中一個服務的人不會一直看到另一個的錯誤；用 API key 登入 Codex 的人重新安裝後 Codex 會停用（ADR-0007）

### Fixed
- 整合後審查（#37／#38／#39／#40 合併後）：
  - 收集器：`/usage` 額度行的百分比位數多到溢位、重置時間的小時不在 1～12、同一個額度印兩行、模型名稱含奇怪字元或超過 32 字，一律回報格式改變；各模型額度的 id 改為 `[a-z0-9_]`（`Sonnet 4.5 only` → `weekly_sonnet_4_5`）；解析前去除終端機色碼並以 `NO_COLOR` 執行 claude；`config.json` 的 `claude_path` 不是字串時當成沒設定
  - 收集器：中繼回 4xx 時把它的錯誤原因附在日誌（之前只有「HTTP 422」）
  - 安裝腳本：找不到 `claude` 指令時不再把 `enabled_providers` 改成只有 Codex（Claude 的登入狀態是「不知道」，維持原設定並提示）
  - 中繼：body 上限提高到 64 KiB（原本 16 KiB 裝不下 LIMITS 允許的最大快照）；拒絕含小數秒的時間（iOS 17／macOS 14 解不出來）與不存在的日期（2 月 30 日）；需重新部署 Worker
  - 手錶／iPhone：sendMessage 設定同步的訊息格式移到 UsageKit `WatchSettingsMessage` 並加上測試；fixture 測試改經真正的 `/usage` 解析器產生快照
- 中繼：依 schema 驗證上傳的快照（`providers` 必須是物件、百分比、日期、字串長度、數量上限），並只保存白名單欄位，其他欄位移除；需重新部署 Worker（C-12）
- Live Activity：重置時間早於資料過期時間時，卡片不再永遠不轉灰；`staleDate` 在過期前一律給過期時間，過期前的重置在同一次重繪顯示（最多晚 30 分鐘）（C-01）
- 自動重裝：程序被強制結束後殘留的鎖不再永久停止重裝；鎖內記錄 PID，程序已不存在、舊版無 PID 或超過 2 小時的鎖會被接手（C-02）
- 收集器：含 Bearer 密鑰的請求只跟隨同來源（scheme、主機、port 相同）的重新導向，最多 3 次（C-03）
- 收集器：缺少或格式錯誤的百分比回報為格式錯誤，不再當成 0% 已用（C-04）。Codex 以 API 欄位驗證；Claude 改用 `/usage` 輸出後（ADR-0006）以額度行驗證，任何一行認不得就整個回報格式改變，不略過
- iPhone／手錶：讀取密鑰改為先更新、不存在才新增，寫入失敗時保留舊密鑰並顯示錯誤，不同步到手錶（C-05）
- iPhone App 停在前景時每分鐘重算過期、已重置、百分比與最吃緊一項（C-07）
- 資料時間比裝置時間晚超過過期門檻時視為過期，Mac 時鐘快了也不會讓舊資料一直顯示成新的（C-09）
- 手錶背景重新整理排程失敗時延後 1、5、15 分鐘重試，App 回到前景時也重新排程（C-10）
- 自動重裝腳本全程使用 launchd 指定的 Python，不再依 PATH 找 `python3`（C-13）
- 收集器：Claude token 過期或 5 分鐘內到期時，委派 Claude Code 續期（`claude -p /usage`，不消耗額度）後重新讀取，不再因為幾小時沒用 Claude Code 而停止更新；續期失敗超過 30 分鐘發一次 macOS 通知。收集器本身仍不刷新、不寫入憑證（ADR-0005）（之後由 ADR-0006 取代，見 Changed）

## [0.5.0] - 2026-10-21

涵蓋路線圖 v0.4（Live Activity）與 v0.5（捷徑）兩個里程碑，沒有單獨發布 v0.4.0。Mac 選單列 App（v1.2）與 Apple Watch App（v1.4）一起合併，以預覽版提供：需要 Team 簽署與 App Group，尚未在實機驗證。

### Added
- iOS Live Activity：鎖定畫面與動態島顯示各服務各額度、最吃緊的一項、重置倒數與更新時間；進度條使用服務識別色、剩餘 < 20% 轉紅；過期資料轉灰；動態島以「CL」「CX」區分服務；單一服務失敗不影響另一服務（FR-8, FR-11, FR-12, FR-15, FR-16，#24）
- Live Activity 上的「更新」按鈕，不開 App 即可更新（FR-9，#24）
- 重置時間已過的額度顯示「已重置」（FR-26）；可切換顯示已用或剩餘 %（FR-17）（#24）
- Apple Watch 智慧型堆疊的精簡版面，只顯示最吃緊的一項（FR-27，#24）
- 捷徑動作「重新啟動用量監看」，可搭配定時自動化（07:00、15:00、23:00）突破 Live Activity 8 小時上限（FR-10，#25）
- UsageKit：`UsageActivityState`（Live Activity 狀態，限制在 4KB 內）、依時間判斷重置的百分比與顯示模式、`UsagePalette`（色值與對比度計算）（#24）
- iOS Debug 示範模式 `AUM_DEMO`，以假資料截圖（只在 Debug 建置）（#24）
- 預覽：Mac 選單列 App，選單列顯示最吃緊額度的剩餘 % 與顏色，面板列出所有額度、進度條、重置倒數與更新時間，監看本機 `usage.json`（FR-21, FR-22，#26）
- 預覽：Mac 桌面小工具（小、中兩種尺寸；需 Team 簽署與 App Group 才能顯示真實資料，FR-24）；最短每 25 分鐘重新整理一次，一天最多 58 次（#26）
- UsageKit：`UsageFileLocator`，與收集器相同的 `usage.json` 路徑規則（#26）
- 預覽：Apple Watch App，列出所有可見額度與重置倒數（FR-29）；錶面複雜功能顯示最吃緊額度（圓形、矩形、單行，FR-28）；約每 30 分鐘背景重新整理（#27）
- iPhone 以 WatchConnectivity 把中繼設定傳到手錶（FR-30，尚未以實機驗證，#27）
- UsageKit 支援 watchOS 11（#27）
- ADR-0004（提議中）：用量歷史資料的存放方式，比較本機檔案、中繼保存多筆與兩者並用，列出待決定問題（#23）
- README「隱私與安全」章節：網路請求、資料存放位置與已知取捨（NFR-6，#27）
- 共用範例資料 `fixtures/usage-sample.json`，收集器、relay 與 UsageKit 各有測試讀同一份；`scripts/verify-all.sh` 一次跑完測試與三個 App 的 Debug／Release 建置；實機手動測試清單 `docs/manual-test-checklist.md`（#27）

### Changed
- 顏色規則（FR-16）：進度條改用服務識別色（Claude 珊瑚橘、Codex 青綠），剩餘 < 20% 才轉紅；百分比文字一律 primary；「資料已過期」等提示文字共用同一個顏色，對比度符合 WCAG AA。色值集中在 UsageKit `UsagePalette` 與 UsageKitUI `UsageColors`（#24）
- Live Activity 的 Widget 擴充最低支援 iOS 18（手錶版面需要），App 本身仍支援 iOS 17（#24）
- 手錶 App 與錶面複雜功能的過期門檻為 45 分鐘（背景更新約每 30 分鐘且常延後）；iPhone、Mac 與 Live Activity 維持 30 分鐘（FR-11，#27）
- iOS、Mac、watchOS App 版本號改為 0.5.0；收集器版本改為 0.5.0

### Fixed
- 收集器：空的 `AI_USAGE_MONITOR_HOME` 視為未設定，與 App 行為一致（#26）

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

[Unreleased]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.3.0...v0.5.0
[0.3.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kevin930326/ai-usage-monitor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kevin930326/ai-usage-monitor/releases/tag/v0.1.0
