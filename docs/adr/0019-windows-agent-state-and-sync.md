# ADR-0019：Windows 的 AI 狀態與跨裝置狀態

- 狀態：**已接受**（2026-10-29；第二版，Fable 5.1 對抗式審查 17 項全部處理，見 PR）。第 1 節（Windows 的 hook）在 mascot2 第 4a 部分實作；第 2 節（跨裝置）在第 4b 部分
- 日期：2026-10-29
- 相關：ADR-0011（第二層、裝置密鑰）、ADR-0012（iPhone 配對）、ADR-0015（Windows App 不連網）、ADR-0016（角色）、ADR-0017（hook）

## 背景

ADR-0017 讓 Mac 用 hook 知道 Claude Code 與 Codex 的確切狀態。使用者也在 Windows 上用這兩個 AI，而且常常人不在那台電腦前：
想在 Mac 的瀏海、Windows 的圓環、iPhone 上看到「桌機：需要你」。

限制：

- Windows App 不連網、不用 socket／named pipe／網址（ADR-0015 第 2 節，`check-no-network.py`）。
- Mac 與 Windows App 都不直接連中繼；只有收集器（Python，兩邊同一份）連中繼。
- iPhone 沒有 APNs（個人簽名，沒有推播憑證）。
- 資料夾名稱只能顯示，不能落地、不能上傳（ADR-0017 第 5 節）。Windows 上不顯示資料夾名稱（見第 1 節）。
- hook：標準輸出不印、任何錯誤 exit 0、App 沒在跑時立刻結束、不連網。
- 不能從任何地方（瀏海、圓環、通知）核准或拒絕 AI 的操作。

## 決定

### 1. Windows 的 hook

**程式**：隨 Windows App 發佈的 `aum-hook.exe`（主控台程式，framework-dependent、ReadyToRun，和 App 同一個資料夾；只參考 UsageCore 的
`AgentHookInput`，不用 socket、named pipe、網址，`check-no-network.py` 照樣檢查）。

- 整個 `Main` 包在 try/catch，結束時一律 `Environment.Exit(0)`；不寫標準輸出、不寫標準錯誤。
- stdin 以位元組讀（最多 1 MB）再當 UTF-8 解析，中文使用者名稱與資料夾路徑不受代碼頁影響（F-04）。
- 先開具名 Mutex `Local\io.github.kevin930326.AIUsageMonitor.Windows`（App 的單一執行個體 Mutex）：打不開表示 App 沒在跑，立刻結束、不寫檔。
  App 當機時 Mutex 立即消失，沒有空窗（F-07；不需要 alive 檔）。
- 不用 Python 的理由（F-01、F-05）：exec form 直接執行 `python.exe 腳本` 時，腳本不見會以結束碼 2 結束，Claude Code 把 2 當成「阻擋」並把錯誤文字放進對話；
  Python 路徑隨版本變動、`python.exe` 在桌面版會閃主控台。`aum-hook.exe` 不在時是「無法執行」，由 `onFailure: continue` 處理（Claude Code）。

**設定**（安裝、修好、移除照 ADR-0017 第 3 節：備份、保留其他設定的鍵順序、替換前重讀檢查變更）：

- Claude Code：exec form，`command` 是 `aum-hook.exe` 的完整路徑、`args` 是 `["claude"]`、`onFailure: "continue"`、`timeout: 3`。不經 Git Bash／PowerShell。
- Codex：`commandWindows` 是 `"<完整路徑>\aum-hook.exe" codex`（路徑一律加雙引號；路徑含 `"`、`%`、`^`、`&` 時不安裝並提示）。辨識自己的項目以 `aum-hook.exe` 子字串。
  測試涵蓋含空白與中文的路徑（F-06）。Codex 對 Windows 上無法執行的處理官方沒寫：實機驗證後寫進報告。
- 設定檔位置照收集器的規則（`token_stats.log_dirs`）：`config.json` 的 `claude_config_dir`／`codex_home`，其次 `CLAUDE_CONFIG_DIR`／`CODEX_HOME` 環境變數，
  其次使用者資料夾的 `.claude`／`.codex`（F-17）。隔離模式（`--isolated`，測試、截圖、效能量測）一律用資料夾裡的假使用者資料夾。
  C# 的 `JsonObject` 保留鍵順序，但縮排會變成兩格；設定頁說明。
- 「需要修好」：設定裡的路徑不是目前 App 資料夾的 `aum-hook.exe`，或那個檔案不在。
- WSL 裡跑的 AI 不支援（設定檔在 Linux 側），寫進 BACKLOG。

**傳送**（ADR-0017「hook 寫檔、App 監看資料夾」原本不採用；Windows 例外，因為 ADR-0015 不准用 socket 與 named pipe，F-03）：

- hook 把一個事件寫成一個檔案到 `%LOCALAPPDATA%\AIUsageMonitor\agent\inbox\`（`AI_USAGE_MONITOR_HOME` 優先），檔名 `<UTC 時間 ns，20 位補零>-<8 位隨機>.json`，
  先寫暫存檔再改名（原子）。內容只有 ADR-0017 的訊息格式：`v, ai, ev, need, sub, sid, t`，`dir` 一律是空字串（Windows 上不顯示資料夾名稱）；單檔 ≤ 1 KB。
  `sid` 是工作階段 ID 加鹽的雜湊，鹽在 `agent\salt`（App 第一次啟動時建立，32 位元組隨機，只有使用者自己可讀）。
- inbox 已有 256 個檔時 hook 不再寫（App 沒在處理，不讓檔案堆積）。
- 寫完觸發具名事件 `Local\io.github.kevin930326.AIUsageMonitor.Windows.agent`。App 等這個事件（不輪詢），每分鐘也掃一次作為退路；
  不用 FileSystemWatcher（緩衝溢位會漏事件）。
- App 每次掃**整個資料夾**、依檔名（時間）排序處理、處理後刪除；讀檔用 `FileShare.ReadWrite | Delete`，刪不掉（防毒軟體鎖檔）留到下一次；
  格式不合（`AgentHookMessage.Parse` 的嚴格標準寫法）直接刪。事件以 hook 端的時間套用（夾在現在與 12 小時前之間），
  退路掃描或當機後留下的事件也照實際發生的時間算，太舊的立刻淘汰。App 啟動時處理留下的（只刪處理過的，啟動中途寫入的不會被刪），結束時清空。
- 設定檔的備份與換上的檔案在建立時就套上原檔的 DACL，不會繼承資料夾較寬鬆的權限；巢狀的重複鍵也當成「格式不對、不改」。

**狀態機與畫面**：UsageCore 的 `AgentSessions`（已有）。只顯示要你注意的三種（`RingAgent`，取優先順序最高的工作階段）：

- 需要你：圓環（含貼邊的半圓標籤與展開的膠囊）外緣一圈琥珀色外框。
- 完成未看：右下角綠色勾勾徽章；出錯：右下角紅色驚嘆號徽章（白邊）。形狀不同，不只靠顏色。
- 文字：展開膠囊的第二行改成「Claude Code 需要你」＋說明（第一行的額度保留）；圓環與系統匣的提示、螢幕閱讀器的名稱在最前面加上同一句。
  系統匣圖示右下角一個同色小點。
- 打開面板＝看過了：完成未看與出錯變回等你（同 Mac 展開瀏海）。

需要你超過 N 秒、長任務（跑超過 M 分鐘）完成時（設定，預設同 Mac 20 秒、3 分鐘；0＝關閉）以通知區域圖示的氣球提示
（`Shell_NotifyIcon` 的 `NIF_INFO`＋`NIIF_RESPECT_QUIET_TIME`，Windows 10 起顯示成通知、遵守專注；不用註冊 AUMID）通知，
同一段狀態只發一次（`AgentNoticeLog`），只寫 AI 與種類。**沒有任何按鈕**（F-12）。顯示方式是「只有懸浮圓環」時沒有系統匣圖示，不通知（設定頁說明）。

**時間**：冷、熱啟動各量 100 次寫進報告；目標同 Mac（< 50 ms），`timeout: 3`（F-15）。

### 2. 跨裝置（預設關閉）

**本機彙總**：每台電腦的 App 把彙總狀態寫到本機 `agent-state.json`：`{"v":1, "ais":[{"ai","state","sessions","since"}]}`
（AI、最高狀態、工作階段數、進入這個狀態的時間；同一個狀態有幾個工作階段時取最早進入的，哪一個最近有事件不影響彙總），不含資料夾、工作階段 ID 或任何內容。狀態改變時寫並觸發同步（1 秒內的多次改變合併成一次觸發）；內容一樣時每 5 分鐘重寫一次、不觸發
（收集器把 10 分鐘沒更新的檔當成 App 沒在跑）；App 正常結束時寫「全部閒置」並觸發。
彙總規則與「本機＋遠端合併顯示」放進 `fixtures/agent/cases.json` 的 `summary`、`remote` 兩組 golden，Swift、C#、Python 三邊跑（F-13）。

**只同步狀態的入口**（F-02）：`python -m usage_collector agent-sync`：只讀 `agent-state.json`、只連 `/agents/state`，不跑 CLI、不上傳 `/usage`，
不用「立即更新」的節流（`CollectorKicks`），自己最短 60 秒一次（等候後重讀 `agent-state.json`，送出的是最新的狀態）。

- Mac：新的 LaunchAgent，沒有排程，App 寫了檔（內容改變）後以 `launchctl kickstart` 觸發（同「更新」按鈕的做法）。內建收集器的是 App 內的
  `<bundle ID>.agent-sync.plist`，和收集器一起以 `SMAppService` 註冊與解除；`install-launchd.sh` 的是 `io.github.kevin930326.ai-usage-monitor.agent-sync`。
  （實作時修訂：原本用 `WatchPaths` 監看 `agent-state.json`，但 App 內的 plist 不能寫使用者的絕對路徑；兩種安裝方式改用同一個做法。）
- Windows：新的排程 `\AIUsageMonitor\AgentSync`（`install-task.ps1` 建立），App 寫完檔以 `schtasks /Run` 觸發（仍只在 `SystemServices.cs`），獨立 60 秒節流。
- 一般 5 分鐘一輪也做一次狀態同步，作為退路。

**上傳前檢查**（F-11）：App 沒在跑（Mac：socket 不在；Windows：Mutex 不在）或 `agent-state.json` 超過 10 分鐘沒更新時，上傳一次「全部閒置」後不再傳；
內容雜湊和上次上傳的一樣就不傳（存在收集器的 meta）。

**中繼**（F-08）：D1 新表 `agent_state(device_id, ai, state, sessions, since, updated_at, PRIMARY KEY(device_id, ai))`（migration）。

- `POST /agents/state`：**裝置密鑰**，整台覆蓋（device_id 由密鑰決定，不能寫別台）。body ≤ 1 KB；`ai ∈ {claude, codex}`、`state` 是六個白名單值、
  `sessions` 0～32 整數；`updated_at` 由中繼寫，`since` 夾在 `[updated_at − 24h, updated_at]`。
- `GET /agents/state`：**讀取密鑰**，回 `{"now", "devices":[{"device_id","name","ais":[…],"updated_at"}]}`，不含撤銷的裝置與 30 分鐘內沒有更新的裝置；
  用戶端再以 `now − updated_at` 判斷 30 分鐘內才顯示（用中繼的時鐘）。全部閒置時中繼留一列標記（`ai` 為空字串，不回傳），其他電腦才知道這台還在。
- 撤銷裝置時一併刪除它的 AI 狀態。
- `AGENT_SYNC` 不是 `on` 時兩個端點回 404；沒有 D1 綁定時回 503（同第二層）。
- 中繼只改程式與測試，**不部署**；部署步驟見報告。

**權限**（F-09）：修訂 ADR-0011 第 2 節：裝置密鑰可寫 `/tokens/daily` 與 `/agents/state`。前提：這台電腦已經啟用第二層（有裝置密鑰、已上傳過一次，知道
`relay_device_id`）；要看其他電腦的狀態還要有讀取密鑰（Windows：`set-tier2.ps1 -ReadKey`）。下載時略過自己的 `device_id`，寫到 `agent-remote.json`。

**開關與相容**（F-10）：每台電腦的 `config.json` 的 `agent_sync: true`（`set-tier2.sh --agent-sync`／`set-tier2.ps1 -AgentSync` 寫入；App 不寫 config.json）。
收集器用自己的 meta 鍵（`agent_upload_*`）；404 視為「中繼不支援」：記一次日誌、1 小時後再試、不算進第二層的撤銷計數。

| 組合 | 行為 |
|---|---|
| 舊收集器＋新中繼 | 沒影響（不呼叫新端點） |
| 新收集器＋舊中繼或 `AGENT_SYNC` 關閉 | 404 安靜，1 小時後再試 |
| 舊 App＋新收集器 | 沒有 `agent-state.json`，不上傳；忽略 `agent-remote.json` |
| 新 App＋舊收集器 | 沒有 `agent-remote.json`，不顯示其他電腦 |

**顯示**：裝置名稱是第二層設定的名稱。

- Mac 瀏海：「AI 工作階段」分頁在這台的工作階段之後列出其他電腦（電腦圖示＋名稱、AI、狀態、工作階段數）；不改變收合時的外框與數量。
- Windows 圓環：這台沒有要注意的時，顯示其他電腦的「需要你」（膠囊第二行「工作 PC：Codex 需要你」）。其他電腦的完成、出錯不上圓環：這裡看過也消不掉。
- iPhone App：打開時與下拉更新時讀 `GET /agents/state`，首頁列出「其他電腦」；404 或逾時時不顯示這一區、不影響額度。
  小工具不讀（實作時修訂：小工具空間小、更新間隔 15～60 分鐘，列進 BACKLOG）。

### 3. iPhone 沒有推播

- 做得到：App 在前景或背景更新（`BGAppRefreshTask`，系統決定頻率）時更新顯示與即時動態；小工具時間軸更新時（約 15～60 分鐘）。
- 做不到：「需要你」的即時通知、即時動態即時更新（需要 APNs）。寫進 BACKLOG：若之後有付費開發者帳號，可用推播更新即時動態。

## 考慮過的選項

- **Python 的 `aum_hook.py`（收集器的 Python）**：不用裝新程式；但腳本不見時結束碼 2 會擋住 AI、Python 路徑隨版本變、會閃主控台。不採用（F-01、F-05）。
- **具名共享記憶體＋具名事件**（磁碟上不留檔）：不用寫檔；但 hook 與 App 要約定環狀緩衝與鎖，App 沒在跑時事件會掉、多個 hook 同時寫要處理競爭。
  寫檔的內容已經沒有資料夾與內容、處理後就刪，先用檔案；之後若要更少落地再換。
- **FileSystemWatcher**：緩衝溢位會漏事件、只看單一檔會漏順序。改用具名事件叫醒＋掃整個資料夾。
- **用「立即更新」觸發同步**：會跑完整的收集、上傳 `/usage`，KV 寫入額度與 FR-50 的節流都會被吃掉。不採用。
- **中繼用 KV 存狀態**：每台每分鐘一次會超過 KV 每天 1,000 次寫入。改用 D1。

## 不做

- 不上傳資料夾名稱、工作階段 ID、任何對話或指令內容；Windows 上不顯示資料夾名稱。
- 不從 Windows App 直接連中繼或開 socket／named pipe（ADR-0015）。
- 通知與圓環沒有核准／拒絕按鈕；不能從任何地方操作 AI。
- 不在通知裡寫是哪台電腦的哪個資料夾。
- 不支援 WSL 裡跑的 AI（BACKLOG）。

## 影響

第 4a 部分（第 1 節，已做）：

- 修訂 ADR-0015 第 2 節：App 除了自己的設定，還建立 `agent\salt`、`agent\inbox\`，並刪 inbox 的檔；使用者按「連接」時改 Claude Code／Codex 的設定檔
  （先備份）；多一個 `aum-hook.exe`。
- 修訂 ADR-0017「考慮過的選項」（hook 寫檔在 Windows 例外採用）與「影響」（Windows 的傳送方式）。
- 新增：`aum-hook.exe` 專案；UsageCore 的 `AgentHookConfig`、`AgentHookFiles`、`AgentInbox`、`RingAgent`、`AgentNoticeLog`；
  App 的 `AgentMonitor`、`AgentHookInstaller` 與設定頁的「AI 狀態」。

第 4b 部分（第 2 節）：

- 修訂 ADR-0011 第 2 節（裝置密鑰可寫 `/agents/state`）。
- 修訂 ADR-0015 第 2 節（App 還寫 `agent-state.json`；多一個排程）。
- 新增：UsageCore 的彙總與遠端合併、收集器 `agent-sync`、中繼 D1 migration 與兩個端點、`fixtures/agent` 的 `summary`、`remote`。
