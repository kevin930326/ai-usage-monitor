# ADR-0015：Windows 桌面 App（懸浮圓環＋面板）

- 狀態：**提議中**（2026-10-26）
- 日期：2026-10-26
- 相關需求：FR-48、FR-49、FR-61、FR-62（本 ADR 新增）、NFR-1、NFR-3、NFR-7、NFR-8、NFR-9、NFR-10
- 相關：[ADR-0008](0008-mac-panel-layout.md)（面板、App 不連網）、[ADR-0009](0009-local-history-and-token-stats.md)（本機歷史）、[ADR-0010](0010-mac-animation-principles.md)（動畫）、[ADR-0011](0011-multi-device-usage.md)（Windows 收集器、第二層）、[ADR-0013](0013-download-and-install.md)（安裝與發布）、[ADR-0014](0014-long-term-operation.md)（長期使用）

## 背景

Windows PC 已經有收集器（ADR-0011：工作排程器每 5 分鐘統計 Token、可選第二層上傳），但 PC 上看不到額度，要看 Mac 的選單列或 iPhone。
BACKLOG 第 9 節記了「Windows 懸浮圖示」：桌面上可拖動的小圓環顯示剩餘最少的額度，點一下展開面板。這份 ADR 決定技術、架構、收集器的變更、計算邏輯怎麼和 Mac 保持一致、懸浮窗的行為、效能目標、截圖與安裝方式，以及分階段的範圍。

設計由 Fable 5.1 subagent（只讀）提出，主 session 對照程式與官方文件驗證後寫成；查證來源列在最後。

## 決定摘要

| # | 題目 | 決定 |
|---|---|---|
| 1 | 技術 | **C#／WPF／.NET 10 LTS**，`win-x64` 與 `win-arm64`；不用 WinUI 3。面板在 Windows 11 22621 以上用 DWM 的 Acrylic（`DWMSBT_TRANSIENTWINDOW`），其他情況純色 |
| 2 | 架構 | 與 Mac 相同：**收集器負責連網與密鑰；App 只讀本機檔案**（`usage.json`；階段 2 起 `history.sqlite3` 唯讀、階段 4 起 `service-status.json`），不連網、不持有密鑰、不寫收集器的檔案 |
| 3 | 桌機收集器 | 「收集額度」沿用 `install-task.ps1 -WithQuota`（只寫本機）；新增 `set-tier2.ps1 -ReadKey`（讀取密鑰存認證管理員、下載其他電腦的每日加總）；**PC 仍不上傳額度快照**；貼上密鑰時檢查格式 |
| 4 | 計算一致性 | UsageKit 的純邏輯移植成 C# `UsageCore`；共用輸入 `fixtures/logic/cases.json`，由 Swift 產生 `golden.json`，C# 必須算出相同結果，CI 兩邊都跑 |
| 5 | 範圍 | 階段 1：懸浮圓環、面板（頁首、主圓環卡片、額度卡片）、右鍵選單、系統匣、設定、動畫、立即更新、安裝腳本、截圖與效能 CI。階段 2～4 見第 5 節 |
| 6 | 懸浮窗 | 最上層但不搶焦點（`WS_EX_NOACTIVATE`）、自己處理拖動、貼齊工作區邊緣、每個螢幕記住位置、Per-Monitor V2、同螢幕有全螢幕 App 時自動隱藏（事件驅動）、透明度 |
| 7 | 效能 | 閒置 CPU ≤ 0.1%、面板開啟靜止 ≤ 2%、關閉後 1 分鐘 ≤ 0.3%、重複開關記憶體 ≤ +5 MB；全 App 只有一個每分鐘的計時器；面板關閉即銷毀 |
| 8 | 截圖、安裝 | `RenderTargetBitmap` 以示範資料與固定時間產生截圖（CI artifact）；`scripts/install-windows-app.ps1` 從 repo 建置（framework-dependent）、可重跑、`-Uninstall`；之後 Release 提供自含式 zip；未簽章，說明 SmartScreen |

## 1. 技術

| 項目 | 決定 |
|---|---|
| 框架 | **.NET 10（LTS，支援到 2028-11-14）**。.NET 8 與 9 的支援在 **2026-11-10** 結束，新專案不用 |
| UI | WPF。圓環、進度條、卡片自己畫（`OnRender`／`DrawingContext`，同 Mac「控制項自己畫」）；設定視窗的標準控制項用 WPF 的 Fluent 主題（`ThemeMode`，.NET 9 起；程式碼存取要 `NoWarn WPF0001`） |
| 架構 | `win-x64`、`win-arm64` 各一份（自含式一定要指定 RID）；WPF 自 .NET 6 起原生支援 ARM64 |
| 純邏輯 | `UsageCore` 是一般的 `net10.0`（不參考 WPF），Mac 與 Linux 能建置與測試 |
| Mac 上的建置 | `brew install dotnet`（10.0.x）＋ `EnableWindowsTargeting=true`：Mac 可以編譯整個方案（含 XAML）並跑 `UsageCore.Tests`，**不能執行 WPF**；發行檔一律在 Windows（CI）建置 |
| 系統匣 | `Shell_NotifyIcon` 的 P/Invoke（不引入 WinForms：少一個框架、記憶體較小，也避開 WinForms 對 manifest DPI 設定的建置錯誤 WFO0003） |

### 與 WinUI 3 比較（不採用）

| 面向 | WPF | WinUI 3 |
|---|---|---|
| 執行環境 | 自含式 publish 後零相依 | 要 Windows App Runtime（未打包時另裝） |
| 無邊框透明的懸浮圓環 | `AllowsTransparency`（層疊視窗，逐像素 alpha），成熟 | 透明的頂層視窗支援弱，要自己接 Composition |
| 材質 | `DwmSetWindowAttribute` 一行 | 內建 `SystemBackdrop` |
| 離線截圖 | `RenderTargetBitmap` 純軟體繪製，不需要 GPU 也不需要顯示視窗 | 要 XAML 樹在已顯示的視窗內 |
| Mac 上編譯 | 可以 | 官方只支援 Windows |

懸浮圓環與 CI 截圖兩項 WPF 明顯較好；材質的差距用 DWM 補回。

### 材質與透明視窗

層疊視窗（`AllowsTransparency=true`）與 DWM 材質互斥，所以視窗分開處理：

| 視窗 | 樣式 | 材質 |
|---|---|---|
| 懸浮圓環 | `WindowStyle=None`、`AllowsTransparency=true`、透明背景 | 不用材質（圓環本身就是圖形） |
| 面板 | `WindowStyle=None`、`AllowsTransparency=false`、`WindowChrome`（`GlassFrameThickness=-1`、`CaptionHeight=0`）、透明背景 | Windows 11 22621 以上：`DWMWA_SYSTEMBACKDROP_TYPE`（38）＝`DWMSBT_TRANSIENTWINDOW`（3，Acrylic；面板是暫時性視窗）、`DWMWA_WINDOW_CORNER_PREFERENCE`（33）＝圓角、`DWMWA_USE_IMMERSIVE_DARK_MODE`（20）依外觀 |
| 設定 | 一般視窗 | Fluent 主題的預設 |

- **退回**：`DwmSetWindowAttribute` 失敗（Windows 10、Windows 11 21H2）、使用者關閉「透明效果」或高對比時，面板用**不透明純色**（淺色 `#F3F3F3`、深色 `#202020`）。不做 Windows 10 的 acrylic（未公開的 `SetWindowCompositionAttribute`、拖動時閃爍；Windows 10 已於 2025-10-14 結束支援）。
- 截圖畫不出材質（`RenderTargetBitmap` 只畫 WPF 內容），截圖一律用純色底，和 Mac「ImageRenderer 畫不出材質」同一原則。

## 2. 架構：App 只讀本機檔案

- **資料夾**：同收集器 `paths.py`：`AI_USAGE_MONITOR_HOME` 有值用它（截圖、測試、量測），否則 `%LOCALAPPDATA%\AIUsageMonitor`。
- **讀**：`usage.json`（階段 1）；`history.sqlite3`（階段 2，唯讀）；`service-status.json`（階段 4）。階段 1 不讀 `config.json`。
- **寫**：只寫自己的設定 `windows-app.json`（同一資料夾）。**永遠不寫 `history.sqlite3`**：Mac App 的例外（清除歷史、縮短保留期間）在 Windows 改由收集器的指令完成（階段 2）。
- **不連網、不讀認證管理員、不執行 `claude`／`codex`**。唯一啟動的程式是「立即更新」的 `schtasks.exe /Run /TN \AIUsageMonitor\Collector`（觸發使用者自己的排程，不連網、不需要系統管理員）。
- **驗證**：
  1. CI 靜態檢查 `windows/tools/check-no-network.py`：App 與 UsageCore 的原始碼不得出現網路（`System.Net`、`HttpClient`、`WebRequest`、`Socket`、`WinHttp`…）、認證（`CredRead`、`CredWrite`、`PasswordVault`…）的 API；`Process.Start` 只能在觸發收集器的那個檔案；不得有 `PackageReference`（App）；不得用 `CompositionTarget.Rendering`。
  2. 實機：防火牆封鎖 App 的輸出連線後一切正常；Process Monitor 看不到 TCP/UDP 與認證存取（實機確認清單）。
- **檔案變更**：`FileSystemWatcher` 監看**資料夾**（收集器先寫暫存檔再改名，監看檔案本身會在改名後失效，同 Mac 的 `UsageStore`），`*.json`、300 ms 去抖動後重讀；內容與上一份相同時不通知畫面。watcher 出錯時由每分鐘的計時器重讀並重建。閒置時沒有輪詢。
- **SQLite（階段 2）**：Windows 內建的 `winsqlite3.dll`（Windows 10 起，x64／ARM64 都有），開法照 Mac 的 `HistoryStore`：`SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX`（不加 CREATE）＋`PRAGMA query_only = ON`＋`busy_timeout`；不用 `mode=ro`（WAL 下 `-shm` 不存在時開不了）。不用 `Microsoft.Data.Sqlite`（多帶原生 DLL 與一個套件相依）。

## 3. 桌機收集器的變更

| 項目 | 決定 |
|---|---|
| 收集額度 | 沿用 `install-task.ps1 -WithQuota`（`--write-local`：寫 `usage.json`、額度歷史 `quota_samples`、`service-status.json`，**不上傳**）。安裝時提醒裝 `tzdata`（Claude 的重置時間）。不改成預設（D-1） |
| 下載其他電腦的資料 | `set-tier2.ps1 -ReadKey`：提示貼上中繼的讀取密鑰（`READ_TOKEN`），存認證管理員 `AIUsageMonitor/relay-read`；收集器既有的 `_sync_download` 就會每小時下載（條件同 Mac：已知自己的 `relay_device_id`＝第一次上傳成功後）。`-NoReadKey`：刪除讀取密鑰並刪除本機的其他電腦資料（`token_sync forget`）。兩者都不給：不動讀取密鑰（重設寫入密鑰時不會意外關掉下載）。`-Disable` 一併刪除本機的其他電腦資料 |
| 不上傳額度快照 | **PC 不上傳 `/usage`**，iPhone 的資料只由 Mac 上傳（理由見下） |
| 密鑰格式檢查 | `set-tier2.ps1`／`set-tier2.sh` 貼上時：去掉前後空白與換行；寫入密鑰必須是 `aumd_`＋43 字元 base64url（共 48 字元，`relay/src/tokens.ts` 的 `newKey`）；讀取密鑰 20～256 字元、只含 `[A-Za-z0-9+/=_.~-]`、不能以 `aumd_` 開頭（貼錯位置）。不對就當場說明哪裡不對（不回顯密鑰）並重新詢問，最多 3 次（BACKLOG 第 10 節） |
| Mac 的 `set-tier2.sh` | 改成腳本自己以 `read -rs` 讀入、`python3 -m usage_collector.credentials check` 檢查（經標準輸入）、再以 `security -i` 的**標準輸入**存入 Keychain（同 `setup-relay.sh`）：密鑰不出現在任何程序的參數裡。通過檢查的值不含空白與引號，`security -i` 不需要跳脫 |

### 為什麼 PC 不上傳額度快照

1. 中繼的 `/usage` 是單一鍵（最新一筆）：兩台各自每 5 分鐘上傳，iPhone 看到的 `updated_at` 會在兩台之間跳動，時鐘差幾十秒時「新的被舊的蓋掉」，Live Activity 的過期與重置判斷跟著亂。
2. 額度是帳號層級的數字，兩台查到的相同，第二份沒有資訊量。
3. KV 免費額度每天 1,000 次寫入：Mac 排程 288 次＋手動更新上限 100 次（FR-50）；再加一台 PC 就是 676 次，兩台 PC 964 次，沒有餘裕。
4. PC 只有裝置密鑰（中繼設計上只能寫 `/tokens/daily`），上傳 `/usage` 得把 Mac 的全權寫入密鑰放到 PC。
5. 程式現狀就是如此：`install-task.ps1` 從不加 `--upload`，`relay.read_write_token()` 在 Windows 也讀不到密鑰。這份 ADR 把它寫成決定。

### 兩台都收集額度時

- 各自執行 `claude -p /usage`（不呼叫模型、不消耗額度，ADR-0006）與 `codex app-server` 的 `account/rateLimits/read`（約 0.7 秒，ADR-0007）：呼叫次數多一倍，對帳號沒有影響，PC 每 5 分鐘多幾秒 CPU。
- 兩邊查到的是同一個帳號的數字、互不影響；`quota_samples` 各存一份、各自保留與降採樣，不合併（第一層只在本機）。
- 單台的 CLI 版本不同、輸出格式改版只在一台壞時，那一台的該服務顯示錯誤，其他照常（FR-12）。

## 4. 計算邏輯的一致性

- `windows/src/UsageCore`（`net10.0`，零套件相依）對應 UsageKit：`UsageSnapshot`／`ProviderUsage`／`UsageWindow`／`LocalStatus` 與 `UsageDecoder`（先看 `schema_version`）、剩餘最少的額度（`TightestWindow`）、服務順序、過期判斷、重置判斷與有效 %、分級、額度長度與經過比例、預期進度與說明文字、用量節奏（平均速度與近期速度）、圓環狀態（`MenuBarState`）、圓環的額度選擇（`MenuBarWindowChoice`）、近期速度（`QuotaHistory.recentRate`）、重置倒數與更新時間文字、萬／億格式。名稱照 Swift，方便對照。
- **共用輸入** `fixtures/logic/cases.json`：每個情境有 `now`、`snapshot`（usage.json 的內容）、選填的 `choice` 與 `samples`（額度歷史），另有萬／億格式、倒數秒數的清單。
- **golden** `fixtures/logic/golden.json` 由 Swift 產生：UsageKit 的 `LogicGoldenTests` 讀輸入、算出每個情境的欄位，`AUM_UPDATE_GOLDEN=1` 時寫檔，否則與檔案比對（以 JSON 值比較、浮點容許 1e-9）。CI 的 UsageKit job（Linux）與 `verify-all.sh` 因此會確認 golden 與 Swift 一致。
- C# 的 `UsageCore.Tests`（xUnit）讀同一份輸入，算出同樣的欄位，與 golden 逐鍵比對；Linux（CI）、Mac（verify-all）與 Windows（CI）都跑。
- **最容易不一致的地方**，golden 都有案例：
  - 四捨五入：Swift `rounded()` 是 0.5 遠離 0，C# `Math.Round` 預設是銀行家捨入 → 一律 `MidpointRounding.AwayFromZero`（案例 `half-percent-rounding`）。
  - 截斷：倒數的分鐘數 Swift `Int(Double)` 向 0 截斷。
  - 日期：Swift 的 `.iso8601` 不接受小數秒；C# 用同樣的格式（`yyyy-MM-dd'T'HH:mm:ssK`）。
  - 同分的取捨：剩餘相同取較早重置的，沒有重置時間排最後，完全相同保留先出現的。
- 欄位（每個情境）：`stale`、`has_no_providers`、`ordered_providers`、`tightest`、`chosen`（依 `choice`）、`chosen_state`、`least_label`（螢幕閱讀程式的說法），以及每個額度的 `display_name`、`hidden`、`is_reset`、`effective_used_pct`、`effective_remaining_pct`、`remaining_rounded`、`severity`、`state`、`duration`、`elapsed_fraction`、`time_remaining_fraction`、`expected_remaining_pct`、`expected_description`、`pace`／`pace_history`（`ahead_by`、`exhausts_at`、`too_fast`）、`recent_rate_per_hour`、`countdown`。另有 `token_format`（`short`、`full`）、`countdown`、`updated`。
- 時區：階段 1 的欄位都與時區無關（倒數是時間差）。階段 2、3 的計算（2026-10-26 先完成計算、畫面之後做）在情境加 `time_zone`（IANA，
  沒有時為 UTC）：「可撐到星期幾」、額度消耗的整點、Token 統計的「今天」與本週依它計算；golden 有美東（3/8、11/1）與倫敦（10/25）
  日光節約時間切換的那一天（不存在的整點是 0 長度的格子、重複的整點併成 2 小時，同 Foundation）。
- 階段 2、3 另外比對的欄位：`history`（`suggestion`、`upcoming_resets`、`awaiting_start`、`weekly_forecast`、`trends`、`consumption`）、
  `token_cases`（裝置範圍 × 計算方式 × 服務範圍的四個數字、30 天／週／累計長條、熱力圖、各模型、時段，與裝置清單的文字），以及 `duration`。
  Mac 的「這台 Mac」在 Windows 是「這台電腦」，這類平台文字不在 golden 裡，由各自的單元測試檢查。
- 讀取 `history.sqlite3`：`HistoryReader` 照 Mac 的 HistoryStore（讀寫模式不建立檔案＋`query_only`、忙碌時等 1 秒、錯誤不帶訊息），
  但每次讀完就關閉連線（Windows 上開著的檔案不能改名，不能擋住收集器的整理），並設 `NO_CKPT_ON_CLOSE`。SQLite 用系統內建的
  `winsqlite3.dll`（Windows 10 以上都有，只從 System32 載入），維持零套件相依。
- 規則改變時：改 UsageKit → `AUM_UPDATE_GOLDEN=1 swift test --filter LogicGoldenTests` → 改 C# 直到測試通過 → 一起提交。

## 5. 範圍與 Mac 功能對照

| 階段 | 內容 |
|---|---|
| **1** | 懸浮圓環、面板（頁首、主圓環卡片、額度卡片）、右鍵選單、系統匣、設定、動畫、立即更新、安裝腳本、截圖與效能的 CI |
| **2** | 讀 `history.sqlite3`：近期速度（面板的「用得太快」改用近期速度，同 Mac）、建議接下來用、接下來的重置、本週走勢、額度消耗、重置卷、設定「歷史資料」（大小、匯出 CSV；清除與保留期間由收集器的指令） |
| **3** | Token 統計卡片（這台電腦／所有電腦、裝置切換、含快取讀取）、完整統計視窗 |
| **4** | 服務狀態、通知（Windows 通知）、全域快捷鍵、首次設定精靈、系統匣圖示的其他樣式、卡片收合與排序、滑鼠穿透 |

| Mac 功能 | Windows | 階段 |
|---|---|---|
| 選單列雙圓環（FR-33）、四種狀態、顯示的額度（自動＝剩餘最少） | 懸浮圓環＋系統匣圖示（同一個繪圖程式） | 1 |
| 圖示的橫條、只有 %、圓環＋% 樣式 | 系統匣圖示的樣式 | 4 |
| 面板頁首（標題、更新時間、資料過期、更新、設定） | 相同 | 1 |
| 主圓環卡片、額度卡片（方案、進度條、預期標記、倒數、用得較快、服務錯誤、沒有服務的提示） | 相同 | 1 |
| 重置卷那一行 | 相同 | 2 |
| 建議接下來用、接下來的重置、本週走勢、額度消耗 | 相同 | 2 |
| Token 統計、完整統計視窗 | 相同，範圍標籤「這台電腦」 | 3 |
| 服務狀態 | 相同（讀 `service-status.json`） | 4 |
| 更新按鈕（`launchctl kickstart`，FR-50） | `schtasks /Run`，同 `CollectorKickThrottle` 的節流（60 秒一次、24 小時 100 次）；排程不存在時頁首提示執行 `install-task.ps1 -WithQuota` | 1 |
| 右鍵選單（FR-47） | 圓環與系統匣：打開面板、立即更新、設定、隱藏圓環、結束 | 1 |
| 設定：圖示樣式與額度、外觀（FR-51） | 顯示方式（懸浮圓環／系統匣／兩者）、圓環的額度、大小、透明度、全螢幕時隱藏、開機自動啟動、外觀 | 1 |
| 卡片收合、區塊開關與排序（FR-35、36） | 階段 1 固定順序、不收合 | 4 |
| 通知、快捷鍵、設定精靈 | Windows 通知、`RegisterHotKey`、精靈 | 4 |
| 動畫（ADR-0010 第一階段） | 打開面板時主圓環描繪、進度條長出、預期標記淡入 | 1 |
| 內建收集器、`.dmg`（ADR-0013） | 不適用：收集器仍是 `install.ps1`／`install-task.ps1` 的排程，App 另外裝 | — |

- **階段 1 的差異**：Mac 的面板有歷史時用近期速度判斷「用得太快」，Windows 階段 1 不讀資料庫，面板與圓環都用本額度開始至今的平均速度（同 Mac 的選單列圖示）。同一份資料兩邊的「約 N 分鐘後用完」可能不同，階段 2 補齊（D-2）。
- 滑鼠提示：「Claude 每週 剩 63% · 4天 2小時後重置」，倒數用共用的 `ResetCountdown`（在 golden 裡）；已重置為「已重置」；非正常狀態在後面加「用得較快」「剩不到 20%」「資料已過期」。

## 6. 懸浮窗的行為

| 項目 | 做法 |
|---|---|
| 最上層、不搶焦點 | `Topmost`、`ShowActivated=false`、`ShowInTaskbar=false`；`WS_EX_NOACTIVATE`（點它不會成為前景視窗）＋`WS_EX_TOOLWINDOW`（不進 Alt+Tab）。被其他 topmost 視窗蓋住時，在前景視窗改變的事件裡 `SetWindowPos(HWND_TOPMOST, …, SWP_NOACTIVATE)` 重新排到前面；不輪詢、不每秒搶最上層 |
| 拖動與點一下 | 不用 `DragMove()`（進入系統的移動迴圈會啟用視窗）：按下時捕捉滑鼠，移動超過 `SystemParameters.MinimumHorizontalDragDistance`／`Vertical` 才算拖動並自己移動視窗；放開時沒拖動就是點一下（開關面板）。失去捕捉時結束拖動 |
| 貼齊邊緣 | 放開時以圓環所在螢幕的**工作區**（扣掉工作列）為準，距離邊緣 ≤ 16 DIP 就吸到那一邊、留 8 DIP 邊距；角落可同時吸兩邊 |
| 記住位置 | 每個螢幕一筆：鍵＝裝置名稱＋解析度＋DPI（例如 `\\.\DISPLAY1|2560x1440|144`），存 `windows-app.json`，最多 16 筆。啟動時找相同的鍵 → 同裝置名稱（比例換算）→ 主螢幕工作區右下角內縮 24 DIP；最後一律夾進該螢幕的工作區（一定看得見）。顯示設定改變（螢幕拔掉、解析度）時重新套用 |
| 多螢幕與 DPI | `app.manifest` 宣告 Per-Monitor V2；WPF 處理 `WM_DPICHANGED`，跨螢幕拖動時 DIP 尺寸不變 |
| 全螢幕時隱藏 | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`（`WINEVENT_OUTOFCONTEXT`，事件驅動）：前景視窗不是自己、不是桌面與工作列（`Progman`、`WorkerW`、`Shell_TrayWnd`、`Shell_SecondaryTrayWnd`），在圓環所在的螢幕、且矩形（`DWMWA_EXTENDED_FRAME_BOUNDS`）涵蓋整個螢幕（不是工作區）、不是有標題列的最大化視窗（工作列自動隱藏時它也涵蓋整個螢幕）→ 隱藏圓環與面板。另外 `SHQueryUserNotificationState` 回報獨占全螢幕的 D3D（`QUNS_RUNNING_D3D_FULL_SCREEN`）或簡報模式、且前景視窗在圓環的螢幕上時也隱藏（這兩個是全系統的狀態）；`QUNS_BUSY` 不用（它是全系統的狀態，另一個螢幕全螢幕時也會回報）。前景視窗沒變但進入或離開全螢幕（瀏覽器按 F11、影片按 Esc）：對**目前前景視窗的執行緒**掛 `EVENT_OBJECT_LOCATIONCHANGE`／`EVENT_OBJECT_DESTROY`（`SetWinEventHook` 的 `idProcess`＋`idThread`；前景改變時換掛），回呼只處理 `idObject = OBJID_WINDOW` 且是前景視窗本身的事件，合併成 250 ms 內一次判斷（拖動視窗時不連續判斷）。事件只在那個執行緒的視窗移動或改變大小時才有，閒置時沒有回呼。可在設定關閉（前景改變的 hook 仍掛著，用來把圓環重新排到最上層、收起沒能啟用的面板） |
| 透明度 | `Window.Opacity`（層疊視窗的整體 alpha，不重繪），30～100%，預設 100% |
| 滑鼠穿透 | 階段 4（`WS_EX_TRANSPARENT`；開啟時必須同時顯示系統匣，否則無法操作） |
| 面板 | 要被啟用才收得到 `Deactivated`：面板不加 `WS_EX_NOACTIVATE`（搶焦點是使用者點圓環的結果，同 Mac 點選單列圖示），加 `WS_EX_TOOLWINDOW`。寬 360 DIP，高度依內容、上限為工作區高度 − 40 DIP（超過時捲動）。位置：貼著圓環、間距 8 DIP，優先放在圓環內側（圓環貼右邊就放左邊），候選位置第一個完全在工作區內的採用；從系統匣打開時放在工作區右下角。收起：失去焦點（點面板外）、Esc、再點一次圓環。**收起＝關閉視窗**，下次重新建立：關閉後不留任何計時器與動畫是結構上的保證 |

## 7. 效能

| 狀態 | 門檻（x64 桌機實測為正式紀錄） | CI（windows-latest，雜訊大） |
|---|---|---|
| 閒置（圓環顯示、面板關閉） | CPU ≤ 0.1% | 記錄；> 0.3% 警告 |
| 面板開啟、靜止 | ≤ 2% | 記錄；> 4% 警告 |
| 動畫播放中 | 記錄最大值 | 記錄 |
| 關閉後 1 分鐘 | ≤ 0.3% | 記錄；> 0.6% 警告 |
| 重複開關後記憶體 | 工作集 ≤ +5 MB | 同（失敗） |

- CPU% ＝ `TotalProcessorTime` 的差 ÷ 經過時間 ÷ 處理器數 × 100（工作管理員的算法）；記憶體看 `WorkingSet64` 與 `PrivateMemorySize64`。
- **計時器**：整個 App 只有一個 `DispatcherTimer`，對齊整分鐘、之後每 60 秒（`DispatcherPriority.Background`）：更新圓環的內圈與狀態（內容以整數化的鍵比較，相同就不重繪）、面板開著時更新倒數與更新時間。不用每秒更新的相對時間。全螢幕隱藏期間照跑但不畫。
- **動畫**：`DoubleAnimation` 驅動自訂的 0…1 進度屬性（同 Mac `PanelMotion`），`FillBehavior=Stop`，完成時寫入最終值（不留 AnimationClock）；不用 `CompositionTarget.Rendering`（靜態檢查）。面板關閉時視窗銷毀。
- **量測**：`windows/tools/measure-perf.ps1`：`AI_USAGE_MONITOR_HOME` 指到暫存資料夾、放示範的 `usage.json`，啟動 Release 版 App，每秒以 `Get-Process` 取樣；以第二個執行個體的命令（`--show-panel`、`--hide-panel`，具名事件）開關面板兩次；輸出各階段的平均與最大值，寫進 PR。Release 版也能量測（不需要 Debug 的示範程式）。

## 8. 截圖、測試與安裝

### 截圖

- Debug 版的 `--render <資料夾> --now <ISO>`：以示範資料與固定時間，不顯示視窗、直接 `Measure`／`Arrange` 後 `RenderTargetBitmap`（2×，192 DPI）存 PNG：懸浮圓環四種狀態（棋盤格底，看得出透明）、系統匣圖示、面板（正常、過期、錯誤、只有一個服務、沒有服務）、設定，淺色與深色各一份。輸出後檢查圖不是單一顏色（CI 的工作階段異常時會畫出空白）。
- 畫面上的「現在」一律從 `Clock.Now`（截圖時是 `--now`），不直接用 `DateTime.Now`。
- 示範資料、截圖工具只在 `#if DEBUG`；CI 檢查 Release 的執行檔不含 `--render`。
- 階段 1 只產生截圖（CI artifact，並複製到工作資料夾檢查）；截圖基準比對在畫面穩定後加入（基準環境＝CI 的 Windows Server，因為 Mac 產生不了）。

### 測試

| 層 | 內容 | 在哪跑 |
|---|---|---|
| `UsageCore.Tests` | golden 比對、單元測試 | Linux CI、Mac（verify-all）、Windows CI |
| `LogicGoldenTests`（Swift） | golden 與 UsageKit 一致 | Linux CI（UsageKit job）、Mac（verify-all） |
| App 建置 | `win-x64`、`win-arm64` Release；Mac 上也建置（verify-all） | Windows CI、Mac |
| 靜態檢查 | 不連網、不碰密鑰、只有一處啟動程式、Release 不含示範字串 | Linux CI、Windows CI、verify-all |
| 截圖、效能 | 上面兩節 | Windows CI |
| UI 行為（拖動、貼邊、全螢幕、多螢幕、DPI） | 實機確認清單 | x64 桌機、ARM64 VM |

### 安裝與更新

- **`scripts/install-windows-app.ps1`**（從 repo 建置）：
  1. 找 .NET 10 SDK（`dotnet --list-sdks`）；沒有時詢問一次後 `winget install --id Microsoft.DotNet.SDK.10 --exact`。
  2. 依 `RuntimeInformation.OSArchitecture` 選 `win-x64`／`win-arm64`，`dotnet publish -c Release --self-contained false`（framework-dependent，SDK 已在機器上，約 1 MB）到 `%LOCALAPPDATA%\AIUsageMonitor\WindowsApp.new`。
  3. 停止執行中的 App（具名事件 `quit`，5 秒後仍在才結束程序，只結束安裝資料夾裡的那一個），換上新版（舊版改名 `WindowsApp.old`）。
  4. 開機自動啟動：目前使用者的 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（值 `AIUsageMonitor`）。第一次安裝預設開，之後以 App 的設定為準。
  5. 啟動 App。可重跑（＝更新）；`-Uninstall` 停止、刪除登錄值與安裝資料夾，保留設定檔。
- **Release（之後）**：`release.yml` 加自含式 zip（`win-x64`、`win-arm64`，約 65 MB）與 SHA-256；`install-windows-app.ps1 -FromRelease` 下載、比對 SHA-256 後才解除封鎖。
  - 2026-10-26：zip 與 `SHA256SUMS-windows` 已加入（`scripts/package-windows-app.py`：Release、不含 .pdb 與測試組件、檢查 Debug 專用字串與組件版本；workflow 在 Windows runner 解壓後於沒有 .NET 的環境啟動）；`-FromRelease` 尚未做。第一次發布照 `docs/release-checklist.md`。
- **SmartScreen**：瀏覽器下載的 zip 帶 Mark of the Web，解壓後第一次執行會出現「Windows 已保護您的電腦」→「其他資訊」→「仍要執行」，或先在 zip 的「內容」勾「解除封鎖」。從 repo 建置的檔案沒有 Mark of the Web，不會出現。不簽章（NFR-3：OV／EV 憑證每年數百美元，SmartScreen 信譽仍要累積；Azure Trusted Signing 列為未來選項）。

### 識別字（之後不能改）

| 類別 | 值 |
|---|---|
| 執行檔 | `AIUsageMonitor.exe`（專案 `windows/src/AIUsageMonitor.Windows`） |
| AppUserModelID | `io.github.kevin930326.AIUsageMonitor.Windows` |
| 單一執行個體 Mutex | `Local\io.github.kevin930326.AIUsageMonitor.Windows` |
| 具名事件 | `Local\io.github.kevin930326.AIUsageMonitor.Windows.show`、`.hide`、`.quit` |
| 設定檔 | `%LOCALAPPDATA%\AIUsageMonitor\windows-app.json`（`"schema": 1`） |
| 安裝資料夾 | `%LOCALAPPDATA%\AIUsageMonitor\WindowsApp` |
| 開機自動啟動 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值名 `AIUsageMonitor` |
| 系統匣圖示 | `Shell_NotifyIcon`，`uID = 1`，不用 `guidItem`（GUID 綁定執行檔路徑，repo 建置與 Release 的路徑不同） |
| 工作排程 | 沿用收集器的 `\AIUsageMonitor\Collector` |
| 環境變數 | 沿用 `AI_USAGE_MONITOR_HOME` |

## 資料夾結構

```
windows/
├── AIUsageMonitor.sln
├── Directory.Build.props        # 共用設定（Nullable、TreatWarningsAsErrors…）
├── README.md                    # 建置、測試、截圖、量測、安裝
├── src/
│   ├── UsageCore/               # net10.0 純邏輯
│   └── AIUsageMonitor.Windows/  # net10.0-windows WPF
├── tests/
│   └── UsageCore.Tests/         # xUnit：golden 比對與單元測試
└── tools/                       # 靜態檢查、截圖、效能量測、圖示
fixtures/logic/                  # cases.json、golden.json（Swift 與 C# 共用）
scripts/install-windows-app.ps1  # 使用者執行的安裝腳本（與 install.ps1 並列）
```

## 需要使用者決定

先採用「建議」，之後可改。

| # | 題目 | 選項 | 建議（先採用） |
|---|---|---|---|
| D-1 | PC 的 `-WithQuota` 是否改成預設 | A 維持選用；B 預設收集 | **A**：ADR-0011 的理由不變（額度是帳號層級、Mac 已經在收集）；要看 Windows App 才需要 |
| D-2 | 階段 1 的「用得太快」只用平均速度（與 Mac 面板有歷史時不同） | A 接受，階段 2 補；B 階段 1 就讀資料庫 | **A** |
| D-3 | 滑鼠提示的倒數格式 | A「4天 2小時後重置」（共用 `ResetCountdown`）；B 只取最大單位「4 天後重置」 | **A**（和面板、golden 一致） |
| D-4 | 從 repo 安裝用 framework-dependent | A framework-dependent（約 1 MB，依賴已裝的 SDK）；B 自含式（約 160 MB） | **A**（Release zip 用 B） |
| D-5 | Windows 10 | A 可執行，面板純色；B 不支援 | **A** |
| D-6 | 歷史資料的清除與保留期間（階段 2） | A App 完全唯讀，由收集器的指令執行；B 比照 Mac App 的例外 | **A** |

## 與現有文件的關係

- **ADR-0011** 第 2 節「Windows 收集器」與第 6 節「只有 Mac 存了讀取密鑰時才下載（Windows 只上傳）」：改為「存了讀取密鑰的電腦才下載」；Windows 收集額度仍是選用（`-WithQuota`）。「裝置密鑰只能寫 `/tokens/daily`、額度快照只由 Mac 上傳」不變。
- **需求文件**：新增 FR-61（Windows 桌面 App）、FR-62（PC 可選收集額度與下載其他電腦的資料、貼上密鑰時檢查格式）；NFR-7 補「Windows 以 C# 移植，以 `fixtures/logic` 的 golden 保證一致」；NFR-8／NFR-10 補 Windows 的門檻（第 7 節）。
- **ADR-0009** 第 1 節（App 只讀，例外是清除與縮短保留期間）：Windows App 沒有這個例外（D-6）。
- **ADR-0013**：Windows 多了 App 的安裝腳本，之後 Release 多兩個 zip。
- **設計 skill**：第 5 節的識別字表加 Windows；第 8 節的「現在」加 Windows 的 `Clock.Now`。

## 實機確認（使用者）

x64 桌機（Windows 11）與 ARM64 VM（Parallels）的清單在 `windows/README.md`「實機確認」：安裝、焦點不被搶、拖動與貼邊、點一下開關面板、點外面收起、全螢幕隱藏（切換到全螢幕 App、同一個視窗按 F11 進入與離開、另一個螢幕全螢幕時不隱藏）、多螢幕與 DPI、拔掉螢幕、開機自動啟動、單一執行個體、外觀切換、透明效果關閉時的純色、防火牆封鎖後仍正常、閒置效能。

## 查證來源

- .NET 支援期限：https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- `EnableWindowsTargeting` 等 MSBuild 屬性：https://learn.microsoft.com/en-us/dotnet/core/project-sdk/msbuild-props
- WPF .NET 9／10 的 Fluent 主題：https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net90 、https://learn.microsoft.com/en-us/dotnet/desktop/wpf/whats-new/net100
- WPF ARM64：https://devblogs.microsoft.com/dotnet/net-july-2021/
- `DWMWINDOWATTRIBUTE`、`DWM_SYSTEMBACKDROP_TYPE`（22621）：https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute 、https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type
- 擴充視窗樣式：https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
- `SetWinEventHook`：https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook
- `SHQueryUserNotificationState`：https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shqueryusernotificationstate
- `WM_DPICHANGED`：https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
- `winsqlite3` 與 Microsoft.Data.Sqlite：https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/custom-versions
- `RenderTargetBitmap` 只有軟體繪製：https://github.com/dotnet/wpf/pull/9024
- GitHub runner 映像：https://github.com/actions/runner-images
- Windows 10 支援結束：https://www.microsoft.com/en-hk/windows/extended-security-updates
- Mark of the Web：https://textslashplain.com/2016/04/04/downloads-and-the-mark-of-the-web
