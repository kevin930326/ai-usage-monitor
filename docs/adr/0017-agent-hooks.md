# ADR-0017：用 hook 取得 AI 的確切狀態

- 狀態：**已接受**（2026-10-28；Fable 5.1 對抗式審查 12 項全部處理，見 PR）。2026-10-29 mascot3 修訂：「不做」寫明虛擬機與 WSL 裡的 AI 不偵測
- 日期：2026-10-28
- 相關：[ADR-0016](0016-mascot-character.md)（角色；本 ADR 取代它「看紀錄資料夾修改時間判斷工作中」的作法，沒接 hook 時才退回）、[ADR-0009](0009-local-history-and-token-stats.md)（本機紀錄）、[ADR-0015](0015-windows-desktop-app.md)（Windows 版，第 4 部分接上同一套）
- 設計來源：工作資料夾 `design/mascot2-TASK.md` 第 1、2 部分；`design/mascot/RESEARCH-2026-10-28.md`

## 背景

ADR-0016 的角色只能從 `~/.claude/projects`、`~/.codex/sessions` 的修改時間猜「AI 在工作」：分不出「等你批准」「做完了」「出錯了」，也不知道有幾個工作階段。使用者要的是瀏海直接告訴他「哪個 AI 需要你」。

本 ADR 決定**怎麼拿到狀態**（hook、傳送、安裝、狀態規則）；瀏海與選單列**怎麼顯示**（需要你的提示、完成通知、工作階段列表）是工作資料夾 `design/mascot2-TASK.md` 第 2 部分的另一個 PR。這個 PR 只把工作中與睡覺接上角色。

Claude Code 與 Codex 都有官方的 hook：在固定的時間點執行一個指令，事件內容以 JSON 從標準輸入傳入。這是唯一不讀對話紀錄就能知道確切狀態的方法。

### 官方文件（2026-10-28 查閱，不憑記憶）

**Claude Code**（code.claude.com/docs/en/hooks）

- 設定：`~/.claude/settings.json` 的 `hooks.<事件>` 是 matcher 群組陣列，每組 `{"matcher": "...", "hooks": [{"type": "command", "command": "...", "timeout": 秒}]}`；沒有 `args` 時指令經過 shell。
- 共同欄位：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、`permission_mode` 等。
- 事件（本 ADR 用到的）：`SessionStart`（`source`：startup／resume／clear／compact／fork）、`SessionEnd`（`reason`：clear／resume／logout／prompt_input_exit／other）、`UserPromptSubmit`（含 `prompt`）、`PreToolUse`／`PostToolUse`／`PostToolUseFailure`（含 `tool_name`、`tool_input`、`tool_response`）、`PermissionRequest`、`Notification`（`notification_type`：permission_prompt、idle_prompt、elicitation_dialog、agent_needs_input 等，另有 `message`、`title`）、`Stop`（含 `last_assistant_message`）、`StopFailure`（`error`：rate_limit、overloaded、authentication_failed…）、`SubagentStop`、`PreCompact`。
- 標準輸出：`UserPromptSubmit`、`SessionStart` 等事件的標準輸出**會加進 Claude 的上下文**；結束碼 2 會擋住提示或工具。使用者中斷時**不會**觸發 `Stop`。
- 互動模式下，在使用者接受資料夾信任前不會執行任何 hook。

**Codex**（learn.chatgpt.com/docs/hooks，原 developers.openai.com/codex/hooks）

- 預設開啟（`[features] hooks = false` 可關；`codex_hooks` 是舊名）。設定可放 `~/.codex/hooks.json` 或 `~/.codex/config.toml` 的 `[hooks]`，多個來源會**疊加**、不互相覆蓋。JSON 形狀與 Claude Code 相同。
- 事件：`SessionStart`、`SessionEnd`、`SubagentStart`、`SubagentStop`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`PreCompact`、`PostCompact`、`UserPromptSubmit`、`Stop`、`Interrupt`（**沒有** Notification，也沒有 API 錯誤事件）。共同欄位多一個 `model`，與回合有關的事件有 `turn_id`。
- `Stop`、`SubagentStop` 結束碼 0 時若有輸出必須是 JSON；**沒有輸出算成功**。`SessionEnd`、`Interrupt` 的逾時預設 1 秒、最多 3 秒。
- **非受管理的 hook 要先在 Codex 的 `/hooks` 審查並信任才會執行**，信任綁在 hook 內容的雜湊，改了要重新信任。

## 決定

### 1. hook 程式（`aum-hook`）

- Swift 命令列程式，隨 App 打包在 `AI Usage Monitor.app/Contents/Helpers/aum-hook`，用 `Foundation` 與 `CryptoKit`，沒有其他相依。啟動到結束目標 < 50 ms（量測方法與數字見 PR）。
- 第一個參數是 AI（`claude` 或 `codex`），從標準輸入讀事件（最多 1 MB，超過就丟掉）。
- **只取**下列欄位，其餘立刻丟掉、不存、不轉傳：
  - AI（來自參數，不信任輸入）；
  - 事件類型（`hook_event_name`，只接受白名單內的名稱）；
  - 需要你的種類（`need`）：Claude 的 `notification_type` 對到 `permission`（permission_prompt）、`question`（elicitation_dialog、agent_needs_input）、`idle`（idle_prompt）；`PreToolUse` 的工具若是 `AskUserQuestion` 記為 `question`、`ExitPlanMode` 記為 `plan`（**只傳種類，不傳工具名稱**）；`PermissionRequest` 記為 `permission`。Codex 沒有 Notification，官方文件也沒說 `request_user_input` 會觸發 PreToolUse：程式照樣認這個名字（對不到就當一般工具），但 Codex 的「問你問題」目前**沒有可靠的訊號**，列在實機確認清單；
  - 是否來自子代理（`sub`，輸入有 `agent_id` 時為 true；只記有沒有，不記 ID 或代理種類）；
  - 工作階段 ID：`SHA-256(本機鹽 ‖ session_id)` 的前 16 個十六進位字元；原始 ID 不離開 hook；
  - 時間（hook 自己的時鐘，毫秒）；
  - 工作目錄的**資料夾名稱**（`cwd` 的最後一段，去掉控制字元、最多 48 字）：只給畫面用，App 只放在記憶體，不寫磁碟、不寫日誌、不上傳；
  - AI 程序的 PID（`pid`，第 7 節；2026-10-29 加入）：hook 的父程序，是 shell 時再往上一層。只讀父程序的**程序名稱**判斷是不是 shell，不讀命令列或任何內容。
- `prompt`、`tool_input`、`tool_response`、`message`、`last_assistant_message`、`transcript_path`、完整的 `cwd` **一律不讀進任何變數以外的地方**：解析後只挑上面幾個欄位。
- **標準輸出與標準錯誤都不印任何東西**；任何錯誤（解析失敗、鹽不存在、socket 不存在、送不出去）都 exit 0，不擋 AI。
- App 沒在跑（鹽或 socket 不存在、連線被拒）時立刻結束；連線與送出各有 100 ms 上限，不會卡住 AI。
- 設定檔裡的指令結尾是 `2>/dev/null || true`：App 被移動或刪掉後，找不到程式時也沒有輸出、結束碼 0（見「影響」）。
- 不連網路：只連本機 Unix socket。
- 程式本身：關掉標準輸出與標準錯誤（導到 `/dev/null`）、忽略 SIGPIPE、`alarm(1)` 到時直接 `_exit(0)`；標準輸入是終端機時不等。
- 實測（`scripts/measure-hook-latency.sh`，Debug 版、100 次）：App 沒在跑時中位數約 4 ms，App 在聽時約 4.5 ms，最大都在 10 ms 內（偶爾一次 40 ms 左右）。

### 2. 傳送：Unix socket

- 位置：`~/Library/Application Support/AIUsageMonitor/agent/hook.sock`。`agent/` 資料夾權限 0700，socket 0600；鹽 `agent/salt`（32 個隨機位元組）0600，App 啟動時建立。測試與截圖時這些都在暫存資料夾（`AI_USAGE_MONITOR_HOME`）。
- 每次連線送一行 JSON（最多 1 KB）：`{"v":1,"ai":"claude","ev":"Stop","need":"","sub":false,"sid":"0123456789abcdef","t":1761650000000,"dir":"my-project","pid":4321}`，送完就關。`ev` 是官方的事件名稱。`pid` 放最後、只在大於 0 時寫（2026-10-29 加入；版本仍是 1：舊格式沒有 `pid` 照收，hook 隨 App 打包，不會有新 hook 配舊 App。草稿原本打算把 `v` 改成 2，實作時改成可省略的欄位，舊的 golden 與中繼都不用動）。App 只收**標準寫法**：解析後重新編碼必須和收到的一字不差（鍵的順序、沒有空白、整數），`1.0`、`1e3`、重複鍵都不收，Swift 與 C# 一樣嚴格。
- App 端：只接受同一個使用者（`getpeereid` 的 uid 與自己相同）的連線；每個連線最多讀 1 KB、250 ms（連線改回阻塞模式，由讀取逾時把關）；格式不對、欄位不在白名單、版本不認得就**丟掉**，不當機、不寫日誌內容（只計數）。接受連線後每條各自在並行佇列讀（同時最多 32 條，再多的直接關掉），backlog 128；解析好的事件才回到主執行緒。
- 每秒最多處理 40 個「只代表還在跑」的事件（一般工具的前後、子代理、壓縮），其餘丟掉：塞假事件不會吃滿 CPU。決定狀態的事件（開始、結束、送出提示、需要你、通知、停止、出錯、中斷）稀少又關鍵，**永遠不丟**——子代理多時正常使用一秒也可能超過 40 個，丟掉 Stop 會讓狀態卡在工作中。
- App 結束（含被 SIGTERM 終止）時移除 socket；hook 看到沒有 socket 或連線被拒就立刻結束。
- 最壞情況：同一使用者底下的其他程式可以送假事件，讓角色顯示錯的狀態（例如假的「需要你」）；或開很多連線佔滿同時讀取的名額，讓真的事件被關掉（hook 照樣安靜結束，狀態因此過時）。它拿不到任何資料（socket 是單向的，App 不回傳東西），也不能讓 App 去做任何事（沒有批准功能，見「不做」）。同一使用者的程式本來就能直接改 AI 的設定檔，所以不再加防護。假事件也可以填任意 `pid`：App 只列**自己這個使用者**的程序底下（Mac 比對 `pbi_uid`，Windows 比對登入工作階段），填 launchd 或系統程序時當成找不到；填自己的其他程序最多讓角色顯示背景執行中 30 分鐘（第 7 節，Fable F-02）。

### 3. 安裝與移除

- 設定的「AI 狀態」區塊（瀏海面板之後）有 Claude Code 與 Codex 兩列：按鈕旁邊一直寫著會改的檔案（預設 `~/.claude/settings.json`、`~/.codex/hooks.json`；資料夾照收集器的規則，`config.json` 的 `claude_config_dir`／`codex_home` 優先，再來是環境變數，和 Windows、活動偵測一致）與加上的事件，按鈕依狀態是「連接」「修好／移除」或「移除」。
- 每個 hook 項目：`{"hooks": [{"type": "command", "command": "'<App>/Contents/Helpers/aum-hook' claude 2>/dev/null || true", "timeout": 3}]}`（不設 matcher；路徑用單引號包起來，經 shell 也安全；逾時 3 秒是 Codex `SessionEnd`、`Interrupt` 的上限）。
- 設定檔是符號連結（例如 dotfiles 管理）時，讀、備份、寫都對連結指向的檔案做：原子寫入會把連結本身換成一般檔案，讀到的權限也會是連結的 0755。
- 修改前先把原檔複製成 `<檔名>.aum-backup-<年月日-時分秒>`（放在真正的檔案旁邊；同一秒第二次加序號，不覆蓋舊備份；建立時就用原檔的權限）；每個設定檔只留最新的 3 份我們的備份（設定檔可能有金鑰，副本不無限累積）。以原子方式寫入並保留原檔權限。檔案不是合法 JSON、或 `hooks` 不是物件時**不改**，只提示。
- **只合併自己的項目**：我們的項目以指令裡的 `Contents/Helpers/aum-hook` 認出；別人的 matcher 群組與 hook 一律保留，同一事件可以和其他瀏海 App 的 hook 共存；重複按「連接」不會加第二份。保留原本的鍵順序（自己寫的有序 JSON 解析器），只動 `hooks` 底下我們的項目。
- 移除只刪自己的項目；某個事件因此變空時刪掉該事件鍵，`hooks` 變空時刪掉 `hooks` 鍵。
- 偵測：App 啟動與打開設定時檢查——hook 指向的路徑不是目前的 App（App 被移動）或缺事件時，顯示「需要修好」與一鍵修好按鈕。
- Codex：寫入後提示「在 Codex 裡執行 `/hooks` 信任這個 hook」；`config.toml` 有 `[features] hooks = false` 時提示 hook 被關掉了。
- 測試全部用暫存資料夾裡的假設定檔；安裝邏輯接受設定檔路徑當參數，不碰真的 `~/.claude`、`~/.codex`。

### 4. 每個工作階段的狀態與彙總（共用邏輯）

狀態：

| 狀態 | 進入的事件 |
|---|---|
| 工作中 `working` | `UserPromptSubmit`、`PreToolUse`（一般工具）、`PostToolUse`、`PostToolUseFailure`；`SubagentStart`／`SubagentStop`／`PreCompact` 與子代理（`sub`）的工具事件只在工作中或需要你時算工作中，不把完成、等你、出錯改回工作中（主回合 Stop 之後背景子代理還會送事件） |
| 需要你 `needsYou`（附種類：權限／問問題／批准計畫） | `PermissionRequest`；`Notification` 的 permission_prompt、elicitation_dialog、agent_needs_input；`PreToolUse` 的問問題與批准計畫 |
| 完成未看 `done` | `Stop`（從工作中或需要你結束） |
| 出錯 `error` | `StopFailure` |
| 等你下一個指令 `waiting` | `SessionStart`（工作中時不變：回合中途自動壓縮也會送 `source=compact`）；`Interrupt`；看過的 `done`；`Notification` 的 idle_prompt（若原本是工作中） |
| 背景執行中 `background`（第 7 節） | 不是事件：`done`、`waiting` 時 AI 程序底下還有回合中新產生的程序（疊在存的狀態上的旗標） |
| 閒置 `idle` | `waiting` 超過「睡覺」分鐘數（同 ADR-0016 的設定；**預設 20 分鐘**，2026-10-29 從 5 分鐘改：Claude Code 叫背景指令等 CI 後結束回合，5 分鐘就睡太快。Mac 只在使用者改過時才存，沒有這個鍵就用新的預設；Windows 的設定檔一直寫出所有鍵，所以多一個「使用者選過」的標記，舊檔沒有標記時值是 5 當成預設、不是 5 當成選過；兩邊的選項都加 20） |

- `SessionEnd` 移除該工作階段。
- **看過**有兩種（2026-10-29，第 8 節）：(1) 使用者展開瀏海或點角色時，所有 AI 的 `done` 變 `waiting`，`error` 也變 `waiting`（`markSeen`）；(2) 切回某個 AI 的宿主程式時，只有那些 AI 的 `done` 變 `waiting`（`markSeenByHost`）。`needsYou` 都不受影響。
- 太久沒有事件：`working` 超過 20 分鐘沒有事件（例如被使用者中斷，Claude Code 不會送 Stop）變 `waiting`；`needsYou` 超過 60 分鐘沒有事件（例如直接關掉終端機，沒送 SessionEnd）變 `waiting`；任何狀態超過 12 小時沒有事件（AI 當掉）移除。App 有工作階段時每分鐘檢查一次。
- 同時最多記 32 個工作階段，超過時丟掉最久沒事件的（防假事件塞爆記憶體）。
- 彙總（瀏海與角色看的那一個）：**需要你 > 出錯 > 工作中 > 背景執行中 > 完成未看 > 等你 > 閒置**；同等級取最近的事件。
- 這套規則放在 `UsageKit/AgentSessions.swift` 與 `UsageCore/AgentSessions.cs`，`fixtures/agent/cases.json` → `golden.json` 兩邊跑同一份（同 ADR-0016 的作法）。
- 角色的「工作中」與睡覺（`AgentSessions.activity`）**逐個 AI** 決定：有 hook 工作階段的 AI 照 hook（只有 `working` 算工作中；`needsYou` 算醒著；`done`、`error`、`waiting` 進入後還沒超過睡覺分鐘數算醒著，超過就可以睡——完成未看的標記保留，只是不讓角色一直撐著不睡），沒有的 AI 照 ADR-0016 的修改時間判斷；所有 AI 都閒置才睡。背景執行中算醒著、不算工作中；背景結束後睡覺倒數從結束的那一刻重新起算（`awakeSince`，不動 `since`，通知與跨裝置的時間照舊；Fable F-11）。

### 5. 隱私

- 磁碟上只有鹽與 socket；事件只在記憶體。日誌只寫計數（收到幾筆、丟掉幾筆，App 結束時一行），不寫欄位內容；連接失敗的日誌只寫是哪個 AI，不寫路徑。
- 資料夾名稱只給畫面用（展開瀏海的「AI 工作階段」列表）；不進 usage.json、歷史、中繼、日誌，也**不進系統通知**：通知中心會把通知內容存在磁碟上，所以通知只寫哪個 AI、要你做什麼（允許、回答、確認計畫、完成），識別碼是隨機值。
- 工作階段 ID 是加鹽雜湊，換鹽（重裝或刪除 `agent/`）後無法和舊的對應。
- 背景工作偵測（第 7 節）只用程序是否存在、PID、父 PID、開始時間，hook 另外讀父程序的名稱；切回宿主程式（第 8 節）只用前景程式的 bundle ID／執行檔名稱。都只在記憶體、比對完就丟，不讀命令列、環境變數、工作目錄、視窗標題或任何內容，不寫磁碟、不寫日誌、不上傳。

### 6. 瀏海上的呈現（mascot2 第 2 部分）

- **需要你**：瀏海外框琥珀色（收合、展開都在，靜止不重畫），角色舉手（新模式 `raise`，優先於工作中與睡覺；收合的迷你角色也舉手）；兩個以上的工作階段時迷你角色旁顯示數量（數字，不是狀態點）。展開時若有需要你的，右邊直接切到「AI 工作階段」分頁：AI、資料夾名稱、狀態文字、多久，需要你的排最前面，最多列 4 個。
- **完成**：一個回合變成 `done` 的那一刻，展開時排隊揮手；收著時瀏海鼓一下、迷你角色揮手（狀態機事件 `cheer`，兩邊 golden）。完成未看、額度正常時角色開心（^ ^），展開或點角色才變回平常。
- **出錯**：角色難過，看過後回到額度的表情。額度偏高、用完、過期的表情優先於「完成未看」的開心，但不優先於出錯。
- **等你下指令**：收合的瀏海每 7 秒沿外框淡淡亮一次（1.6 秒，只在亮的時候每秒重畫 20 次）；設定可關，靜音、勿擾、動畫「關閉」時不亮。
- **系統通知**：需要你超過 N 秒（預設 20）、跑超過 N 分鐘（預設 3；從不在跑進入工作中時記回合開始，需要你之後繼續不算新回合）的回合完成；0 表示關閉。判斷（`AgentSessions.notices`、`nextNoticeCheck`）在共用邏輯並有 golden；App 只去重、照下一次檢查時間排一個計時器，不輪詢。走通知中心（遵守專注模式）；靜音與勿擾時不送也不補送。點通知會展開瀏海並保持展開。
- 動畫程度「簡單」「關閉」時角色姿勢不變（同 ADR-0016），外框、數量與列表照常。

### 7. 背景執行中：AI 在背景等待時不要睡著（2026-10-29，icons 第 2 部分）

**問題**：Claude Code 叫背景指令去等（`gh run watch`、背景 shell）後就結束回合，hook 送出 `Stop`；之後沒有任何 hook 事件，App 當成「完成／等你」，閒置後角色睡著，但 AI 其實還在背景工作。hook 事件裡沒有「還有背景工作」的訊號（2026-10-29 查閱官方 hook 文件：`Stop` 沒有這種欄位）。

**做法：看 AI 程序底下有沒有回合中新產生、回合結束後仍在的子孫程序。**

1. **AI 程序是哪一個**：hook 送 `pid`（第 1、2 節）。Mac 的指令字串含 `2>/dev/null || true`，shell 不會 exec，hook 的父程序是 shell：父程序的**程序名稱**（`proc_name`）在 shell 清單（sh、bash、zsh、dash、fish、ksh、tcsh、csh）裡就往上一層。Windows 的 hook 以 `NtQueryInformationProcess` 只取自己的父 PID（Fable F-03），父程序的執行檔名稱是 cmd、powershell、pwsh、bash、sh 時往上一層、最多兩層：Claude Code 是 exec 形式（父程序就是 AI，npm 安裝時多一層 cmd），**Codex 的 hook 是一行指令、必經 shell**（Fable F-04）。以（PID、開始時間）當識別，避免 PID 重用。一個工作階段記一個 AI 程序（最新的主回合事件說了算）；沒有 `pid` 或找不到那個程序時這個工作階段不偵測。
2. **基準（排除常駐子程序）**：收到 `UserPromptSubmit` 時，App 在背景佇列列出 AI 程序底下所有子孫程序，記成這個工作階段的基準（MCP 伺服器、語言伺服器等常駐的在回合開始前就在）。**上一回合留下、還在跑的候選不併進基準**（Fable F-06：「我在背景等 CI，先回報」→ 使用者回「好」→ 新回合，背景工作仍要算）。沒有基準（App 在回合中途才啟動）時在 `Stop` 拍基準、這一回合不判斷（寧可漏報）。
3. **回合結束後**：**每一次**主回合 `Stop`（存的狀態已是完成也一樣，Claude Code 由背景工作結束自動開的新回合沒有 `UserPromptSubmit`，Fable F-07）後 3 秒列一次，扣掉基準剩下的是**候選**。候選要**連續兩次**（3 秒與 23 秒）都看到同一個才算背景執行中（Fable F-09：只看到一次的多半是其他 App 跑得久的 Stop hook）；這 20 秒畫面仍是完成／等你。之後每 20 秒再看一次：候選都結束、或 AI 程序結束就離開。其他改變狀態的事件（工作中、需要你、出錯、中斷、新開始）都清掉背景、停止檢查（Fable F-13）；`SessionEnd` 移除工作階段。
   - **上限 30 分鐘**（從候選第一次出現起算；Fable F-08 的選項 (a)，和工作中的 20 分鐘逾時同一個量級）：超過時把剩下的併進基準（當成常駐的），回到原本的狀態。草稿是 60 分鐘，但回合中才第一次啟動的 MCP、LSP 會讓本機不睡、其他電腦看到「工作中」一整個小時。
4. **呈現**：背景執行中是疊在存的狀態上的旗標：存的狀態是完成未看、等你（含閒置）時顯示成背景執行中；工作中、需要你、出錯照原本的。背景旗標開著時（Fable F-12）：表情照額度（不是完成的開心）；瀏海的「完成了 N 個」、Windows 圓環的綠勾勾不算它（圓環跳過它，別的工作階段的完成未看照樣顯示）；等你的脈動不亮；`Stop` 的那一刻照常揮手、長任務通知照常（3 秒後才知道有背景工作）。展開瀏海或點角色看過時，完成未看照樣變等你；背景結束後回到存的狀態。
5. **何時查（效能）**：只有「某個工作階段在 `Stop` 後等第一次檢查」或「有候選」時才排計時器；沒有就完全不查。展開或收合都一樣。Mac 從 AI 程序以 `proc_listchildpids` 往下（最多 256 個程序、深度 16），`proc_pidinfo` 取父 PID 與開始時間；Windows 一次 Toolhelp32 快照（只用 PID、父 PID，不讀結構裡的執行檔名稱），再以 `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`＋`GetProcessTimes` 取建立時間，子程序的建立時間早於父程序的當成 PID 重用、不算。都在背景執行緒，結果回主執行緒套用。
6. **誤判情況**（README「已知取捨」寫摘要）：

| 情況 | 結果 |
|---|---|
| MCP／語言伺服器在回合開始前就在 | 不算（在基準裡） |
| 回合中才第一次啟動的 MCP 伺服器、使用者叫 AI 開的開發伺服器 | 誤報：背景執行中，最多 30 分鐘後併進基準 |
| 背景指令 double fork、被重新掛到 launchd／系統程序底下（`nohup … &` 後父程序結束、`setsid`、Windows 的 `start`） | 漏報：顯示完成／等你 |
| 其他 App 的 Stop hook 跑超過 23 秒 | 誤報到它結束為止 |
| 同一個 AI 程序服務多個工作階段（Codex App 的 app-server、子代理） | 背景工作可能算到同程序的別個工作階段上（Fable F-05）；整體「這個 AI 有背景工作」仍正確 |
| AI 經中介程序執行 hook（使用者的 wrapper、`sandbox-exec`） | AI 程序找成中介程序，它結束後 → 不偵測（Fable F-10） |
| AI 程序或子程序的 PID 被重用 | 開始時間不同 → 當成不同程序 |
| App 在回合中途重新啟動 | 那一回合不判斷 |
| 虛擬機、容器、WSL 裡的 AI | 不偵測（同「不做」） |

7. **跨裝置**：`agent-state.json` 把背景執行中寫成 `working`，`since` 用那個工作階段原本的 `since`（`Stop` 的時間，Fable F-14）。中繼與舊版 App 不用改格式。
8. **畫面**：角色新模式 `think`（優先順序：舉手 > 工作中 > think > 睡覺 > 平常）。收合時平常的迷你角色、臉朝正前方不看游標，慢慢呼吸（同睡著的 4.4 秒一次，但眼睛張開）加**慢速的思考泡泡**：每一步取一輪長度 ÷（4 × 圈數）、圈數＝round(一輪 ÷ (520 × 4))，一輪 4398 毫秒時每步約 550 毫秒（同 ADR-0021 的整除算法，Fable F-29），每秒 8 格、約 35 張，以 Core Animation／預先畫好的一輪循環播放。展開時照平常（眨眼、看滑鼠）。列表文字「背景執行中」，顏色同工作中。動畫「簡單」「關閉」、減少動態效果時靜態（同 ADR-0021）。

### 8. 切回 AI 的程式就算看過（2026-10-29，icons 第 3 部分）

**問題**（使用者）：在 Claude App 裡看完回覆、沒點圓環，「完成了」一直掛著。

1. 前景程式換成某個 AI 的宿主程式時，把**這台電腦**上那些 AI 的「完成未看」一起標成已看，並寫 `agent-state.json`。**需要你與出錯不會因為切換程式而清掉**。
2. 要在「完成」之後才切過去才算；完成的那一刻宿主程式已經在前景的，**停留 3 秒**（`AgentHosts.dwellMs`）也算（使用者在 TASK 定的規則）。Fable F-15 指出：終端機與編輯器使用者多數時間就在宿主程式裡，另一個分頁完成的 3 秒後就自動看過；這是使用者選的取捨，列在影響與 README，需要時可改成只對專屬 App 套停留。
3. 宿主程式清單在 `shared/agent-hosts.json`（Mac 的 bundle ID、Windows 的執行檔名稱，不分大小寫）：Claude 桌面 App → claude；Codex 桌面 App → codex；終端機與編輯器 → claude 與 codex 都算（App 不知道終端機裡跑的是哪一個，也不去查；在終端機看 Codex 也會清掉 Claude 的完成未看，Fable F-16）。
4. **只取程式識別**：Mac 用 `NSWorkspace.didActivateApplicationNotification` 的 `bundleIdentifier`（本 App 自己變成前景時不算切換，Fable F-18）；Windows 用 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`（`WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS`，不注入其他程式；委派保留參考），取前景視窗的 PID 再 `QueryFullProcessImageName` 只留檔名。提權（系統管理員）的終端機打不開，不算宿主。不讀視窗標題、不寫日誌、不保存歷史。
5. 判斷是共用邏輯（`markSeenByHost`、`nextHostCheck`，兩邊 golden）：App 只在前景改變、某個工作階段剛完成、或到了停留期滿時呼叫，不輪詢。

### 9. 其他電腦的「完成了」一直掛著（2026-10-29，icons 第 3 部分）

**原因**：其他電腦每 10 分鐘重傳一次（心跳，ADR-0019 第 2 節），「中繼收到超過 30 分鐘就不顯示」永遠不會到；而 Windows `AgentMonitor.MarkSeen()` 只在**彙總**是完成或出錯時才寫 `agent-state.json`，同時有別的工作階段在工作中或需要你時，看過的不會同步出去。修正：C# `AgentSessions.MarkSeen` 回傳有沒有改，有改就寫並重畫（Mac 本來就是）。

**顯示端自動淡出**：其他電腦的「完成了」「出錯」從進入那個狀態（`since`）起超過 30 分鐘（`RemoteAgents.fadeAfter`）就不顯示。`since` 是那台電腦「最早進入該狀態」的時間（多個完成未看時被最老的拖下去，維持 Fable F-01 的選擇，F-19）；用中繼的時鐘換算（`now − since`，加上下載後在本機經過的時間）。對方時鐘慢會提早淡出，快則被中繼夾在 `updated_at` 內（F-20）。`since` 缺或不是非負整數時照舊、不淡出（F-21）。需要你、工作中不淡出。Swift、C# 與 iPhone（`parseRelay` 走同一個 `parse`）同一份規則，golden 有情境。

## 不做

- **不在瀏海上批准或拒絕指令。** 理由：(1) 要批准就得讓 hook 等 App 回覆，hook 會變成會卡住 AI 的雙向通道，違反「任何錯誤都不擋 AI」；(2) 同一使用者的任何程式都能連到 socket，批准功能會讓假事件變成假批准，最壞情況從「顯示錯」變成「替你按允許」；(3) Claude Code 與 Codex 自己的權限畫面會顯示完整的指令內容，瀏海為了隱私刻意不拿這些內容，沒有資訊就不該讓人做決定。
- 不讀對話紀錄（`transcript_path`）判斷狀態。
- 不讀程序的命令列、環境變數或工作目錄來猜背景工作是什麼（第 7 節只看程序樹）；不追沒有父子關係的程序。
- 不在 hook 裡做網路請求、不寫檔。
- **不偵測虛擬機、容器或 Windows 的 WSL 裡跑的 AI**（2026-10-29 使用者決定）：hook 只裝進這台電腦本身的 `~/.claude/settings.json`、`~/.codex/hooks.json`；虛擬機、容器或 WSL 裡的 Claude Code、Codex 通常讀的是它們自己系統裡的設定檔；就算共用了這台的 `~/.claude`（例如 devcontainer 掛進去），裡面找不到 `aum-hook` 或連不到 App 的 Unix socket（Mac 的指令結尾是 `2>/dev/null || true`，安靜結束），所以 hook 的狀態（需要你、完成、出錯）不會出現在瀏海上。例外：共用了這台的紀錄資料夾（`~/.claude/projects`、`~/.codex/sessions`）時，那個 AI 沒有 hook 工作階段，退回的修改時間判斷（`MascotActivityProbe`）分不出紀錄是誰寫的，角色可能顯示「工作中」。Windows 的 WSL 見 [ADR-0019](0019-windows-agent-state-and-sync.md) 第 1 節；README「已知取捨」寫明。

## 考慮過的選項

- **繼續只看修改時間**：分不出需要你、完成、出錯，不採用（保留為退回機制）。
- **HTTP hook（Claude Code 的 `type: "http"`）**：要開本機連接埠，任何本機程式（含瀏覽器頁面）都可能連到；Codex 也不支援。不採用。
- **hook 寫檔、App 監看資料夾**：會在磁碟留下事件紀錄，違反隱私底線。不採用。Windows 例外（[ADR-0019](0019-windows-agent-state-and-sync.md) 第 1 節）：
  App 不能用 socket 或具名管道，改由 hook 寫一個沒有資料夾名稱與內容的小檔、App 處理完立刻刪除，啟動與結束時清空。
- **用 shell 腳本當 hook**：啟動要經過 shell、`jq` 不一定有、要自己處理 JSON 跳脫；不如打包一個小程式。
- **Codex 改寫 `config.toml`**：TOML 合併容易弄壞使用者的檔案；`hooks.json` 是官方支援、會和其他來源疊加的位置。（只逐行看 `[features]` 的 `hooks`／`codex_hooks` 是否為 false，用來提示。）
- **用 `JSONSerialization` 改設定檔**：會打亂使用者檔案的鍵順序與格式；自己寫一個保留順序的小解析器（`OrderedJSON`），只動 `hooks` 底下我們的項目。

## 影響

- 使用者要按一次「連接」；Codex 另外要在 `/hooks` 信任一次。
- App 被移動後 hook 指向舊路徑。Claude Code 經 `sh -c` 執行指令，結束碼非 0 也非 2 時會在**對話裡**顯示 hook error 與標準錯誤的第一行（2026-10-28 官方文件），所以指令結尾加上 `2>/dev/null || true`：找不到程式時什麼都不做、不擋 AI，App 下次啟動時顯示「需要修好」。修好會改變指令，Codex 要再到 `/hooks` 信任一次。（考慮過讓指令指向資料夾裡固定位置的符號連結，搬 App 就不必修；但多一個要維護的連結，App 被刪掉時連結也會留著，先不採用。）
- Windows（第 4 部分）用同一套事件、狀態與 golden，傳送改成 hook 寫檔＋具名事件叫醒 App（[ADR-0019](0019-windows-agent-state-and-sync.md)；ADR-0015 不准 socket 與具名管道）。指令**不能**照搬 `'<路徑>' claude`：Claude Code 在 Windows 沒有 Git Bash 時用 PowerShell，這種寫法是語法錯誤；Windows 改用官方的 exec 形式（`"command": "<exe>", "args": ["claude"]`，不經 shell），`isOurs` 也要同時看 `command` 與 `args`。
- 背景執行中（第 7 節）會誤報與漏報（誤判表）；終端機與編輯器算兩個 AI 的宿主，切過去 3 秒就會把兩個 AI 的完成未看都清掉（第 8 節）。README「已知取捨」寫明。
