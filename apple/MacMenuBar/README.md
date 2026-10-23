# Mac 選單列 App

直接讀取 Mac 收集器寫在本機的 `usage.json`，不經過網路，也不需要讀取密鑰。資料模型與顏色規則來自 [UsageKit](../UsageKit/)。

| 部分 | 內容 |
|---|---|
| 選單列 | 預設雙圓環（外圈剩餘 %、內圈距離重置的時間），另有橫條、只有 %、圓環＋%（FR-33，[ADR-0008](../../docs/adr/0008-mac-panel-layout.md)）；用得太快加小點、剩 < 20% 轉紅、資料超過 30 分鐘未更新轉灰並改為虛線；「只有 %」樣式以 ↑（太快）、!（剩 < 20%）、–（過期）區分；可選擇顯示哪個額度（預設「自動（剩最少的）」）；沒有動畫 |
| 面板 | 點選單列圖示打開，單一長版、卡片式（FR-34），預設順序（ADR-0008）：主圓環卡片（剩餘最少的額度，標題列為服務圖示＋「Claude 每週」、用得較快時顯示約幾分鐘後用完）→ 建議接下來用（FR-39，某服務快用完、另一個還充足時才出現）→ 額度卡片（各服務各額度的進度條、預期進度標記、重置倒數）→ 接下來的重置（FR-40，未來 8 小時的時間軸與每週額度可撐到星期幾）→ 本週額度走勢（FR-41，剩餘 % 曲線、照時間的預期虛線、可切換額度、沒有紀錄的時段畫斜線）→ 額度消耗（FR-42，每小時消耗的熱力圖與每日合計，標「整個帳號」）；卡片可收合（FR-36）；重置時間已過顯示「已重置」，過期資料轉灰並標示「資料已過期」 |
| 設定 | 面板的齒輪按鈕：登入時自動打開、選單列圖示樣式與顯示的額度、面板區塊的開關與拖曳排序、預期進度標記（FR-35）；歷史資料（FR-37）：保留期間、匯出 CSV、清除歷史、清除並重新掃描 |
| 動畫 | 只在面板開啟時執行，「減少動態效果」時直接顯示（[ADR-0010](../../docs/adr/0010-mac-animation-principles.md)）；面板關閉後相對時間文字也停止更新（NFR-8） |

桌面小工具（FR-24）已決定不做，v1.5 起移除：選單列圖示與面板已涵蓋同樣資訊，小工具還需要沙盒、App Group 與 Team 簽署。

## 額度歷史（v1.6）

走勢、額度消耗、重置時間軸的預測與「約 N 分鐘後用完」讀收集器寫的 `history.sqlite3`（同一個資料夾，[ADR-0009](../../docs/adr/0009-local-history-and-token-stats.md)）。App 只讀：

- **只在面板看得見時開啟資料庫**，讀最近 8 天後放在記憶體；面板關閉時關閉連線（NFR-8）。面板開著時監看 `history.sqlite3-wal`，收集器提交新資料（`PRAGMA data_version` 改變）時重讀；收集器先寫 `usage.json`、上傳後才寫歷史，只看 `usage.json` 會落後一輪。
- 以讀寫模式開啟再設 `PRAGMA query_only`：WAL 資料庫沒有 `-shm` 檔時無法用唯讀模式開啟。沒有檔案時不建立。
- 資料庫版本比 App 新時不讀（顯示請更新 App）；比 App 舊時顯示請更新收集器。
- 歷史少於 2 筆時走勢與額度消耗顯示骨架畫面「正在收集，幾小時後開始會有資料」（FR-46）。
- 「用得太快」＝照目前速度會在重置前用完。「目前速度」是近期速度（5 小時額度看最近 1 小時、至少 4 筆且跨 30 分鐘；每週看最近 24 小時、至少 4 筆且跨 12 小時），不足時退回本額度開始至今的平均速度；「約 N 分鐘後用完」與「可撐到星期幾」用同一規則（ADR-0009 第 4 節）。選單列圖示在面板關閉時不讀資料庫，一律用平均速度。
- 設定的「清除歷史」「縮短保留期間」與「清除並重新掃描」是 App 唯一寫入資料庫的地方，執行前都要確認。

## 資料來源

讀取 `~/Library/Application Support/AIUsageMonitor/usage.json`，規則與收集器相同：設定環境變數 `AI_USAGE_MONITOR_HOME` 時改讀該資料夾。收集器以「寫暫存檔再改名」更新檔案，App 監看所在資料夾（改名後監看檔案本身會失效）。另有每 60 秒的計時器重新判斷過期與重置；只有在監看失效時（資料夾還不存在，或被刪除後重建）才改為每 60 秒讀檔，並在資料夾出現後重新監看。

面板的「更新」按鈕（FR-50）：重新讀檔，並以 `launchctl kickstart gui/<uid>/io.github.kevin930326.ai-usage-monitor` 請 launchd 立即執行收集器，收集器寫完後資料夾監看會自動重讀。App 本身不連網。**60 秒內只觸發一次，最近 24 小時最多 100 次**（`CollectorKickThrottle`，存在 App 的 UserDefaults）：每次觸發收集器都會上傳一次快照到中繼，Cloudflare KV 免費額度每天 1,000 次寫入，排程本身已用約 288 次。超過限制時只重讀檔案，頁尾說明原因。設定 `AI_USAGE_MONITOR_HOME`（測試、截圖、效能量測）時不觸發收集器。

App 不開沙盒，才能讀取 `~/Library/Application Support` 與執行 `launchctl`。

## 安裝到「應用程式」

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
| `AUM_RENDER_DIR` | 以 ImageRenderer 輸出 PNG（淺色、深色）：面板 `panel-*.png`、選單列圖示 `menubar-icons-*.png`、設定 `settings-*.png` |
| `AUM_RENDER_FRAMES=1` | 搭配 `AUM_RENDER_DIR`：每個動畫以 30 fps 輸出 PNG 序列並組成 GIF（`anim-*.gif`） |
| `AUM_RENDER_NAME` | 面板 PNG 的檔名前綴（預設 `panel`；其他名稱只輸出面板） |
| `AUM_RENDER_ANIMS` | 只輸出這些動畫（逗號分隔，例如 `trend,skeleton`） |
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
