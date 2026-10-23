# Mac 選單列 App

直接讀取 Mac 收集器寫在本機的 `usage.json`，不經過網路，也不需要讀取密鑰。資料模型與顏色規則來自 [UsageKit](../UsageKit/)。

| 部分 | 內容 |
|---|---|
| 選單列 | 預設雙圓環（外圈剩餘 %、內圈距離重置的時間），另有橫條、只有 %、圓環＋%（FR-33，[ADR-0008](../../docs/adr/0008-mac-panel-layout.md)）；用得太快加小點、剩 < 20% 轉紅、資料超過 30 分鐘未更新轉灰並改為虛線；「只有 %」樣式以 ↑（太快）、!（剩 < 20%）、–（過期）區分；可選擇顯示哪個額度（預設「自動（剩最少的）」）；沒有動畫 |
| 面板 | 點選單列圖示打開，單一長版、卡片式（FR-34）：主圓環卡片（剩餘最少的額度，標題列為服務圖示＋「Claude 每週」、用得較快時顯示約幾分鐘後用完）、額度卡片（各服務各額度的進度條、預期進度標記、重置倒數）；卡片可收合（FR-36）；重置時間已過顯示「已重置」，過期資料轉灰並標示「資料已過期」 |
| 設定 | 面板的齒輪按鈕：選單列圖示樣式與顯示的額度、面板區塊的開關與拖曳排序、預期進度標記（FR-35） |
| 動畫 | 只在面板開啟時執行，「減少動態效果」時直接顯示（[ADR-0010](../../docs/adr/0010-mac-animation-principles.md)）；面板關閉後相對時間文字也停止更新（NFR-8） |
| 桌面小工具 | 小：剩餘最少的額度；中：兩個服務並排（FR-24） |

面板的趨勢圖（FR-23）尚未實作，需要先決定歷史資料存放方式（ADR-0004）。

## 資料來源

讀取 `~/Library/Application Support/AIUsageMonitor/usage.json`，規則與收集器相同：設定環境變數 `AI_USAGE_MONITOR_HOME` 時改讀該資料夾。收集器以「寫暫存檔再改名」更新檔案，App 監看所在資料夾（改名後監看檔案本身會失效）。另有每 60 秒的計時器重新判斷過期與重置；只有在監看失效時（資料夾還不存在，或被刪除後重建）才改為每 60 秒讀檔，並在資料夾出現後重新監看。

面板的「更新」按鈕（FR-50）：重新讀檔，並以 `launchctl kickstart gui/<uid>/io.github.kevin930326.ai-usage-monitor` 請 launchd 立即執行收集器，收集器寫完後資料夾監看會自動重讀。App 本身不連網。**60 秒內只觸發一次，最近 24 小時最多 100 次**（`CollectorKickThrottle`，存在 App 的 UserDefaults）：每次觸發收集器都會上傳一次快照到中繼，Cloudflare KV 免費額度每天 1,000 次寫入，排程本身已用約 288 次。超過限制時只重讀檔案，頁尾說明原因。設定 `AI_USAGE_MONITOR_HOME`（測試、截圖、效能量測）時不觸發收集器。

App 不開沙盒，才能讀取 `~/Library/Application Support`。桌面小工具必須在沙盒中執行，讀不到這個資料夾，所以 App 讀到新資料時會複製一份到 App Group 容器（`~/Library/Group Containers/group.io.github.kevin930326.AIUsageMonitor/usage.json`）給小工具。

- App Group 需要以 Apple 帳號（Team）簽署。App 只有在自己帶有該 App Group entitlement 時才寫入；以「Sign to Run Locally」建置時不寫入（macOS 15 對未授權存取群組容器會跳出詢問），小工具顯示「範例資料 · 未連結 App Group」。
- 收集器每 5 分鐘寫一次，若每次都要求小工具重新整理，一天約 288 次，超過 WidgetKit 的每日預算（約 40～70 次）。App 最短每 25 分鐘才重新整理一次，一天最多 58 次；數字變動最多晚 25 分鐘反映。數字沒變時也每 25 分鐘一次（避免小工具上的資料時間超過 30 分鐘而誤顯示過期）。小工具的時間軸每 15 分鐘一筆，另在重置與過期時間點各加一筆。

## 建置

```bash
brew install xcodegen
cd apple/MacMenuBar
xcodegen generate
open AIUsageMenuBar.xcodeproj
```

預設以「Sign to Run Locally」（`CODE_SIGN_IDENTITY = -`）簽署，不需要 Apple 帳號，`scripts/verify-all.sh` 與 CI 也用這個設定。這時沒有 App Group，桌面小工具顯示範例資料。

### 以 Team 簽署（桌面小工具顯示真實資料）

`project.team.yml` 引用 `project.yml`，只把簽署改為 `Apple Development`／`Automatic`，並為 App 與小工具加入 App Group `group.io.github.kevin930326.AIUsageMonitor`，不需要手改 `project.yml`：

```bash
cd apple/MacMenuBar
DEVELOPMENT_TEAM=<你的 Team ID> xcodegen generate --spec project.team.yml
open AIUsageMenuBar.xcodeproj
```

entitlements 寫在 `*.team.entitlements`，與預設設定的檔案分開。不要在 Xcode 的 Signing & Capabilities 加設定，下次 `xcodegen generate` 會被覆寫。之後再執行不帶 `--spec` 的 `xcodegen generate` 就會回到 Sign to Run Locally。

確認兩個 bundle 都帶有 App Group：

```bash
codesign -d --entitlements - --xml <AIUsageMenuBar.app> | plutil -p -
codesign -d --entitlements - --xml <AIUsageMenuBar.app>/Contents/PlugIns/UsageDesktopWidget.appex | plutil -p -
```

免費 Apple ID（Personal Team）簽署的 Mac App 是否也有 7 天的佈建期限，尚未實測（手動測試 4.4）。

命令列建置：

```bash
xcodebuild -project AIUsageMenuBar.xcodeproj -scheme AIUsageMenuBar -destination 'platform=macOS' build
```

## 開發用

Debug 版本支援下列環境變數。用 `open` 啟動時環境變數不會傳進 App，要直接執行 bundle 內的執行檔：

| 變數 | 作用 |
|---|---|
| `AI_USAGE_MONITOR_HOME` | 改讀這個資料夾的 `usage.json`；設定時不會寫入 App Group |
| `AUM_DEMO_PANEL=1` | 另開一般視窗顯示面板（選單列面板無法以程式打開，截圖用）；改用每次清空的獨立設定，不動到正式設定 |
| `AUM_RENDER_DIR` | 以 ImageRenderer 輸出 PNG（淺色、深色）：小工具 `widget-*.png`、面板 `panel-*.png`、選單列圖示 `menubar-icons-*.png`、設定 `settings-*.png` |
| `AUM_RENDER_FRAMES=1` | 搭配 `AUM_RENDER_DIR`：每個動畫以 30 fps 輸出 PNG 序列並組成 GIF（`anim-*.gif`） |
| `AUM_RENDER_EXIT=1` | 輸出完就結束 |
| `AUM_DEMO_PERF=1` | 搭配 `AUM_DEMO_PANEL=1`：依固定時間表開關面板與觸發動畫，給 `scripts/measure-panel-perf.sh` 量測 CPU 與記憶體 |

```bash
AI_USAGE_MONITOR_HOME=/tmp/aum-fixture AUM_DEMO_PANEL=1 \
  ./build/Debug/AIUsageMenuBar.app/Contents/MacOS/AIUsageMenuBar
```

App 會在 stderr 印出實際讀取的路徑與每次讀到的 `updated_at`。
