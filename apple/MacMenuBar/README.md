# Mac 選單列 App

直接讀取 Mac 收集器寫在本機的 `usage.json`，不經過網路，也不需要讀取密鑰。資料模型與顏色規則來自 [UsageKit](../UsageKit/)。

| 部分 | 內容 |
|---|---|
| 選單列 | 預設雙圓環（外圈剩餘 %、內圈距離重置的時間），另有橫條、只有 %、圓環＋%（FR-33，[ADR-0008](../../docs/adr/0008-mac-panel-layout.md)）；用得太快加小點、剩 < 20% 轉紅、資料超過 30 分鐘未更新轉灰並改為虛線；「只有 %」樣式以 ↑（太快）、!（剩 < 20%）、–（過期）區分；可選擇顯示哪個額度（預設「自動（剩最少的）」）；沒有動畫 |
| 面板 | 點選單列圖示打開，單一長版、卡片式（FR-34），預設順序（ADR-0008）：主圓環卡片（剩餘最少的額度，標題列為服務圖示＋「Claude 每週」、用得較快時顯示約幾分鐘後用完）→ 建議接下來用（FR-39，某服務快用完、另一個還充足時才出現）→ 額度卡片（各服務各額度的進度條、預期進度標記、重置倒數）→ 接下來的重置（FR-40，未來 8 小時的時間軸與每週額度可撐到星期幾）→ 本週額度走勢（FR-41，剩餘 % 曲線、照時間的預期虛線、可切換額度、沒有紀錄的時段畫斜線）→ 額度消耗（FR-42，每小時消耗的熱力圖與每日合計，標「整個帳號」）→ 統計（FR-43，這台 Mac 的 Token：本週、單日最高、最長任務、連續天數、Token 活動、活動熱力圖，標「這台 Mac」；頁尾「完整統計視窗 →」，FR-44）→ 服務狀態（FR-45，都正常時只有一行，服務異常或額度用完時變成卡片並說明是哪一種）；卡片可收合（FR-36）；重置時間已過顯示「已重置」，過期資料轉灰並標示「資料已過期」 |
| 設定 | 面板的齒輪按鈕：登入時自動打開、選單列圖示樣式與顯示的額度、面板區塊的開關與拖曳排序、預期進度標記（FR-35）；歷史資料（FR-37）：保留期間、匯出額度 CSV 與 Token CSV、清除歷史、清除並重新掃描；通知（FR-19）三個開關，「剩不到 20%」預設開（第一次打開 App 時要求權限），其他兩個預設關；快捷鍵（FR-47），預設不設定 |
| 右鍵選單 | 右鍵（或 Control＋點按）選單列圖示：立即更新、完整統計…、設定…、結束（FR-47），系統原生選單 |
| 動畫 | 只在面板開啟時執行，「減少動態效果」時直接顯示（[ADR-0010](../../docs/adr/0010-mac-animation-principles.md)）；面板關閉後相對時間文字也停止更新（NFR-8） |

桌面小工具（FR-24）已決定不做，v1.5 起移除：選單列圖示與面板已涵蓋同樣資訊，小工具還需要沙盒、App Group 與 Team 簽署。

## 外觀（v1.9）

設定 › 外觀：跟隨系統（預設）、淺色、深色（FR-51）。套用到面板、設定、完整統計與設定精靈的視窗（各視窗的 `NSWindow.appearance`，不設 `NSApp.appearance`）；面板開著時切換有 0.3 秒過渡，減少動態效果時直接換。選單列圖示跟隨選單列本身的深淺色。

## 額度歷史（v1.6）

走勢、額度消耗、重置時間軸的預測與「約 N 分鐘後用完」讀收集器寫的 `history.sqlite3`（同一個資料夾，[ADR-0009](../../docs/adr/0009-local-history-and-token-stats.md)）。App 只讀：

- **只在面板看得見時開啟資料庫**，讀最近 8 天後放在記憶體；面板關閉時關閉連線（NFR-8）。面板開著時監看 `history.sqlite3-wal`，收集器提交新資料（`PRAGMA data_version` 改變）時重讀；收集器先寫 `usage.json`、上傳後才寫歷史，只看 `usage.json` 會落後一輪。
- 以讀寫模式開啟再設 `PRAGMA query_only`：WAL 資料庫沒有 `-shm` 檔時無法用唯讀模式開啟。沒有檔案時不建立。
- 資料庫版本比 App 新時不讀（顯示請更新 App）；比 App 舊時顯示請更新收集器。
- 歷史少於 2 筆時走勢與額度消耗顯示骨架畫面「正在收集，幾小時後開始會有資料」（FR-46）。
- 「用得太快」＝照目前速度會在重置前用完。「目前速度」是近期速度（5 小時額度看最近 1 小時、至少 4 筆且跨 30 分鐘；每週看最近 24 小時、至少 4 筆且跨 12 小時），不足時退回本額度開始至今的平均速度；「約 N 分鐘後用完」與「可撐到星期幾」用同一規則（ADR-0009 第 4 節）。選單列圖示在面板關閉時不讀資料庫，一律用平均速度。
- 設定的「清除歷史」「縮短保留期間」與「清除並重新掃描」是 App 唯一寫入資料庫的地方，執行前都要確認。

## Token 統計（v1.7）

統計卡片與完整統計視窗讀同一個 `history.sqlite3` 的 `daily_tokens`、`records`、`record_days`（完整統計視窗另讀 `hourly_tokens`），只讀這台 Mac 的 `device_id`；計算在 UsageKit 的 `TokenStats.swift`。

- 主數字＝input＋cache_write＋output；快取讀取另外列在滑鼠說明。「本週」從本機時間星期一 00:00 起，與上週同一段期間比較。
- 單日最高、最長任務、最長連續天數、累計以收集器的 `records` 為準（不受保留期間影響）；目前的連續天數以 `record_days` 計算，今天還沒用時算到昨天。
- 首次掃描完成前（`meta.first_scan_done`）顯示骨架「正在整理過去的紀錄（N%）」；沒有任何紀錄時顯示「這台 Mac 還沒有 Claude Code 或 Codex CLI 的紀錄」。
- 完整統計視窗打開時另開一個短暫的連線讀完就關，關閉視窗時釋放資料。

## 服務狀態、通知與快捷鍵（v1.8）

- **服務狀態**：讀收集器寫的 `service-status.json`（[收集器 README](../../collector/README.md#服務狀態)），App 本身不連網。超過 30 分鐘沒更新、檔案不存在或該服務抓取失敗時顯示「無法取得」，不當成正常。某服務的可見額度剩 0% 時，與狀態頁一起判斷：「服務異常，不是額度用完」「額度已用完（服務正常）」或兩者同時。異常時橘點呼吸 3 次後停止（3 × 0.8 秒）。「狀態頁」按鈕用 App 內建的網址在瀏覽器打開，不用檔案裡的字串。
- **通知**（`UNUserNotificationCenter`）：剩不到 20%、用得太快（照目前速度會在重置前用完）、額度重置（曾經剩不到 20% 的額度換了一輪）。判斷在 UsageKit 的 `QuotaAlerts`；每個事件一個鍵（種類｜服務｜額度｜這一輪的重置時間），送過的鍵存在 UserDefaults（`notify.sent`，保留 8 天），所以同一輪只通知一次。鍵不論開關都記錄，打開開關時不會補送已經發生的事件。打開任一開關時才向系統要求權限。點通知打開面板、捲到對應的卡片並亮一下（0.6 秒；重置是「接下來的重置」，其他是額度卡片）。
- **右鍵選單與快捷鍵**：`MenuBarExtra` 沒有右鍵選單與「以程式打開面板」的 API，App 在自己的程序內監看選單列圖示上的右鍵，並以選單列按鈕的 `performClick` 打開面板；全域快捷鍵用 Carbon `RegisterEventHotKey`（不需要「輔助使用」權限、不監看其他 App 的按鍵），需要 ⌘、⌥ 或 ⌃ 其中之一（F1～F20 可單獨使用）。
- 手動測試步驟見 [docs/manual-test-checklist.md](../../docs/manual-test-checklist.md)。

## 資料來源

讀取 `~/Library/Application Support/AIUsageMonitor/usage.json`，規則與收集器相同：設定環境變數 `AI_USAGE_MONITOR_HOME` 時改讀該資料夾。收集器以「寫暫存檔再改名」更新檔案，App 監看所在資料夾（改名後監看檔案本身會失效）。另有每 60 秒的計時器重新判斷過期與重置；只有在監看失效時（資料夾還不存在，或被刪除後重建）才改為每 60 秒讀檔，並在資料夾出現後重新監看。

面板的「更新」按鈕（FR-50）：重新讀檔，並以 `launchctl kickstart gui/<uid>/<label>` 請 launchd 立即執行收集器（內建收集器執行中時是 `io.github.kevin930326.AIUsageMenuBar.collector`，否則是 `install-launchd.sh` 的 `io.github.kevin930326.ai-usage-monitor`），收集器寫完後資料夾監看會自動重讀。App 本身不連網。**60 秒內只觸發一次，最近 24 小時最多 100 次**（`CollectorKickThrottle`，存在 App 的 UserDefaults）：每次觸發收集器都會上傳一次快照到中繼，Cloudflare KV 免費額度每天 1,000 次寫入，排程本身已用約 288 次。超過限制時只重讀檔案，頁尾說明原因。設定 `AI_USAGE_MONITOR_HOME`（測試、截圖、效能量測）時不觸發收集器。

App 不開沙盒，才能讀取 `~/Library/Application Support` 與執行 `launchctl`。

## 下載安裝與內建收集器（FR-53、[ADR-0013](../../docs/adr/0013-download-and-install.md)）

發布版的 App 內嵌 Python 3.13（python-build-standalone，固定版本與 SHA-256）與收集器，不需要 repo、不需要自己裝 Python：

```bash
curl -fsSL https://github.com/kevin930326/ai-usage-monitor/releases/download/v<版本>/install.sh | bash
```

下載固定版本的 zip → 比對腳本內的 SHA-256 → 確認 bundle ID 與簽章 → 舊版移到垃圾桶 → 裝到「應用程式」→ 打開。重跑即更新；`bash -s -- --uninstall` 停用內建收集器並把 App 移到垃圾桶，加 `--purge` 另外把資料與日誌移到垃圾桶（先詢問）。也可以下載 `.dmg` 拖到「應用程式」（第一次打開要到「系統設定 › 隱私權與安全性」按「強制打開」）。

第一次打開時 App 以 `SMAppService.agent` 註冊 App 內的 LaunchAgent（`<bundle ID>.collector`，每 5 分鐘、日誌在 `~/Library/Logs/AIUsageMonitor/collector.log`），先以內建的 Python 執行 `usage_collector.setup` 找 claude／codex、偵測登入狀態寫進 `config.json`。設定 › 背景收集器顯示狀態與操作：

| 狀態 | 顯示 | 按鈕 |
|---|---|---|
| 開發版（沒有內嵌 Python） | 使用 install-launchd.sh 安裝的收集器 | — |
| 偵測到 `install-launchd.sh` 的收集器 | 正在使用 install-launchd.sh 安裝的收集器（**不會另外註冊**，避免重複執行與上傳） | 改用內建收集器（停止舊的、舊 plist 移到垃圾桶、註冊內建的） |
| App 不在「應用程式」、或從 .dmg 直接打開 | 需要先把 App 放進「應用程式」資料夾 | — |
| 內嵌的 Python 帶隔離屬性（.dmg） | 需要允許內建收集器執行 | 允許內建收集器執行 |
| 已停用 | 內建收集器已停用 | 啟用 |
| 在「登入項目」被關掉 | 需要在「登入項目」允許背景執行 | 打開「登入項目」設定 |
| 執行中 | 內建收集器執行中（每 5 分鐘） | 停用 |

App 搬到別的位置後 launchd 仍指向舊路徑，App 啟動時發現位置變了會自動重新註冊。內建收集器每次執行前也會檢查 `install-launchd.sh` 的 plist，在的話直接結束（即使兩個都註冊了也不會重複收集）。App 仍不連網、不持有密鑰。

建置發布檔（只寫 `build/`，不上傳）：

```bash
scripts/build-release.sh --version 1.0.0
```

產出 `build/release/1.0.0/` 的 `.zip`、`.dmg`、寫好版本與 SHA-256 的 `install.sh` 與 `SHA256SUMS`。`--test-home <資料夾>` 建置安裝測試版（Debug、bundle ID 加 `.installtest`、收集器只讀寫該資料夾），驗證步驟見 [手動測試清單](../../docs/manual-test-checklist.md) 第 12 節。推 `v*` tag 時 `.github/workflows/release.yml` 建立草稿 Release。

## 首次設定精靈（FR-54）

第一次打開、而且還沒有任何資料（`usage.json` 不存在）時自動打開「設定精靈」視窗；已經在用的人不會看到，從設定 › 一般 ›「重新執行設定精靈」打開。按「完成」後不再自動出現（`wizard.completed`）。判斷規則在 UsageKit 的 `SetupChecklist`（有單元測試）。

| 步驟 | 怎麼判斷 | 需要處理時 |
|---|---|---|
| 1. 放進「應用程式」資料夾 | App 的位置（App Translocation 算不在） | 說明拖到「應用程式」、「強制打開」；「打開『應用程式』資料夾」 |
| 2. 背景收集器 | `CollectorService` 的狀態（與設定相同；舊安裝時有「改用內建收集器」） | 對應的按鈕；第 1 步沒完成時只說明會自動啟用 |
| 3. Claude Code、4. Codex | 內建收集器 `usage_collector.setup --json --dry-run` 的狀態字串＋`usage.json` 有沒有這個服務的資料或錯誤 | 指令與「複製」：沒安裝 `curl -fsSL https://claude.ai/install.sh \| bash`、`npm install -g @openai/codex`；沒登入 `claude auth login`、`codex login`；Codex 用 API key 時 `codex logout`＋`codex login`。只用其中一個服務時另一個是「可選」 |
| 5. 通知 | 通知權限 | 「允許通知」或「打開通知設定」 |
| 6. 登入時自動打開 | `SMAppService.mainApp` | 開關 |
| 7. 外觀 | — | 跟隨系統／淺色／深色 |
| 8. 在 iPhone 上看 | `config.json` 有沒有 `relay_url`（不讀密鑰） | 「打開說明」（用瀏覽器開 README，App 本身不連網） |

狀態：完成（綠色勾）、需要處理（橘色）、可選（虛線圈）。視窗回到前景時與按「重新檢查」時重新檢查，從終端機登入後回來就會更新。

## 開發版安裝到「應用程式」

```bash
scripts/install-mac-app.sh
```

以 Release 建置（Sign to Run Locally）→ 結束執行中的「AI 用量」→ 舊的 `/Applications/AIUsageMenuBar.app` 移到垃圾桶 → 複製新版本 → 打開。之後要更新也是執行同一個指令。`--no-open` 只安裝不打開。需要 Xcode；有裝 XcodeGen 時會先重新產生專案。

登入時自動打開：點選單列圖示 → 齒輪 → 一般 →「登入時自動打開」（`SMAppService.mainApp`）。只有安裝在「應用程式」資料夾的 App 可以開啟，從 Xcode 執行時這個開關是灰的，避免登入項目指向建置資料夾。系統要求允許時，設定會出現「打開『登入項目』設定」按鈕。要移除就關掉開關，或到「系統設定 › 一般 › 登入項目」移除。

## 建置

```bash
brew install xcodegen
cd apple/MacMenuBar
xcodegen generate
open AIUsageMenuBar.xcodeproj
```

以「Sign to Run Locally」（`CODE_SIGN_IDENTITY = -`）簽署，不需要 Apple 帳號，`scripts/verify-all.sh` 與 CI 也用這個設定。

命令列建置：

```bash
xcodebuild -project AIUsageMenuBar.xcodeproj -scheme AIUsageMenuBar -destination 'platform=macOS' build
```

## 開發用

Debug 版本支援下列環境變數。用 `open` 啟動時環境變數不會傳進 App，要直接執行 bundle 內的執行檔：

| 變數 | 作用 |
|---|---|
| `AI_USAGE_MONITOR_HOME` | 改讀這個資料夾的 `usage.json` 與 `history.sqlite3`；設定時「更新」按鈕不觸發真的收集器 |
| `AUM_DEMO_PANEL=1` | 另開一般視窗顯示面板（選單列面板無法以程式打開，截圖用）；改用每次清空的獨立設定，不動到正式設定 |
| `AUM_RENDER_DIR` | 以 ImageRenderer 輸出 PNG（淺色、深色）：面板 `panel-*.png`、選單列圖示 `menubar-icons-*.png`、設定 `settings-*.png`（另有只含「外觀」一段的 `settings-appearance-*.png`，README 用） |
| `AUM_RENDER_FRAMES=1` | 搭配 `AUM_RENDER_DIR`：每個動畫以 30 fps 輸出 PNG 序列並組成 GIF（`anim-*.gif`） |
| `AUM_RENDER_NAME` | 面板 PNG 的檔名前綴（預設 `panel`；其他名稱只輸出面板） |
| `AUM_RENDER_ANIMS` | 只輸出這些動畫（逗號分隔，例如 `trend,skeleton`）；`stats-tour` 是 README 用的統計切換（全部 → Claude → Codex → 全部，每個畫面停 1.5 秒，`scripts/update-readme-images.sh`） |
| `AUM_RENDER_EXIT=1` | 輸出完就結束 |
| `AUM_DEMO_PERF=1` | 搭配 `AUM_DEMO_PANEL=1`：依固定時間表開關面板與觸發動畫，給 `scripts/measure-panel-perf.sh` 量測 CPU 與記憶體 |

```bash
AI_USAGE_MONITOR_HOME=/tmp/aum-fixture AUM_DEMO_PANEL=1 \
  ./build/Debug/AIUsageMenuBar.app/Contents/MacOS/AIUsageMenuBar
```

App 會在 stderr 印出實際讀取的路徑與每次讀到的 `updated_at`。

假的額度歷史（截圖與效能量測用，不碰真實資料）：

```bash
python3 scripts/make-demo-history.py /tmp/aum-fixture normal   # few／fresh／none
```

`normal` 是 7 天、每晚睡眠空檔、3 天前關機 4 小時、Claude 快用完而 Codex 充足；`few` 每個額度 3 筆、`fresh` 只有 1 筆（骨架畫面）、`none` 沒有資料庫。
