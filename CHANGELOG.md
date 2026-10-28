# Changelog

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號採 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

### Fixed
- 瀏海角色（Fable 對抗審查）：「簡單」「關閉」時待著 10 秒不再畫出睡覺的 z；動畫時間改以開機時間計，系統時間倒退時不會凍住又以 60 fps 重畫；展開中換螢幕不再縮回瀏海（收合後才換版面）；示範模式不讀 config.json 的紀錄位置；工作中偵測卡住 30 秒後不再擋住之後的檢查；角色有 VoiceOver 描述（服務、工作中／睡著／待命、額度狀態）
- 「所有電腦」與單一其他電腦的最長連續天數只算目前這段連續，過去較長、已結束的連續被漏掉：改成從每日資料（最近一年）找所有連續區段的最大值，跨電腦的日子合併計算。Mac（UsageKit）與 Windows（UsageCore）一起改，golden 新增「過去較長、現在較短」與跨裝置的情境。這台 Mac 仍以收集器的個人紀錄為準
- Windows 收集器（`install-task.ps1 -WithQuota`）每 5 分鐘閃出空白主控台視窗：claude、codex 改在隱藏的主控台（`CREATE_NEW_CONSOLE`＋`SW_HIDE`）與自己的 process group 執行，它們再啟動的孫程序共用這個看不到的主控台；claude 逾時時也連同孫程序一起結束（Job Object）。macOS 與 Linux 不變

### Changed
- 角色（mascot）的基礎（ADR-0016，提議中）：Mac（UsageKit）與 Windows（UsageCore）共用的動畫鎖與排隊狀態機（一次只播一個、按鈕與狀態觸發的排隊只留最後一個、手勢忙碌時忽略、短反應中連點 5 下插隊轉暈、模式與動畫分開），時間參數在 `shared/mascot-anim.json`，`fixtures/mascot` 的 golden 讓兩邊排出同樣的順序。畫面還沒有用到，App 外觀不變
- Windows App 的 UsageCore（ADR-0015 第 4 節）：移植階段 2、3 的計算（近期速度與沒有紀錄的時段、建議接下來用、重置時間軸、每週預測、本週走勢、額度消耗、Token 統計含裝置範圍與含快取讀取、萬／億與時間長度），golden 新增 15 個額度情境（含美東、倫敦日光節約時間）與 5 個 Token 情境，C# 與 Swift 一致；新增唯讀讀取 `history.sqlite3` 的 `HistoryReader`（系統內建的 SQLite，每次讀完就關閉）。畫面還沒有用到，Windows App 的外觀不變
- 收集器日誌的相同錯誤限頻（ADR-0014 LT-02 後續）：同一行連續出現時每小時只記一行（附持續時間與略過次數），不再出現時記一行「已恢復」；狀態存在日誌旁的 `collector.log.repeats.json`（App 內建收集器是 `collector.log.app.repeats.json`）
- 完整統計視窗開著（看得見）時自動更新（ADR-0014 LT-21）：每分鐘比對 history.sqlite3 的大小與修改時間，收集器寫入後在背景重新讀取、不重播動畫；讀不到時保留原本的數字。視窗被擋住或關閉時不檢查
- ADR-0014（長期使用）改為「已採用」，記錄使用者對 D-1～D-4 的決定：資料庫損毀時改名保留並建新檔、每週備份留 2 份；換機 runbook 加上偵測從別台複製來的資料庫；維持共用讀取密鑰；中繼每月刪除 400 天以前的每日加總。新增 `docs/runbook.md`：換電腦（沿用身分以 `rotate`、另立身分才 `revoke`）、手機或手錶遺失時換讀取密鑰並重新配對
- Token 統計的去重表改為 90 天時間窗（ADR-0014 LT-01，ADR-0009 第 4 節）：比時間窗舊的訊息不計算也不記錄，去重表每天刪掉時間窗以前的列（每次最多 2 萬列），10 年下 `history.sqlite3` 不再無限成長；首次掃描與「清除並重新掃描」照舊讀完整歷史。時間窗的起點每天最多前進兩天、首次設定不超過最新的訊息日期：系統時鐘被設到未來時，統計不會停擺
- `history.sqlite3` 每 30 天（或可回收的空間超過 20%）由收集器 `VACUUM` 並截斷 WAL，縮短保留期間或刪除去重列後檔案會變小；磁碟空間不夠時跳過（ADR-0014 LT-14）
- 磁碟空間不足（剩不到 500 MB）時收集器暫停寫 `history.sqlite3`，`usage.json`、額度快照上傳與服務狀態照常（第二層的每日加總上傳與下載也暫停），Mac 面板底部顯示警告；`usage.json` 寫不進去時不再讓整輪中止、上傳照常；被強制結束留下的暫存檔一天後刪除（ADR-0014 LT-06、LT-20）
- 熱力圖（#74）：「全部」改為藍色 5 階色階（淺色淺藍→深藍、深色暗藍→亮藍），面板的活動熱力圖、完整統計視窗與額度消耗共用同一個色階；Claude、Codex 維持各自的識別色，依階數疊透明度。分級從 4 階改成 5 階，對比由 `UsagePaletteTests` 檢查
- 文件（#88）：README 的安裝改成三層（0. 只有 Mac、1. 加上 iPhone、2. 加上 PC），一行安裝指向固定版本並說明 SHA-256 的保護範圍；新增 `docs/uninstall.md`（各部分怎麼移除、會留下什麼）
- ADR-0012（iPhone 配對）與 ADR-0013（下載與安裝）改為「已採用」，記錄使用者的決定（#90）：發布檔只放 arm64；「允許內建收集器執行」維持由使用者按；第一次發布用 tag 產生草稿 Release；FR-57 以 `relay-device.sh` 的裝置密鑰加入第二層（以短碼加入之後再做）
- 額度重置的判斷（ADR-0009 第 4 節）：`used_pct` 下降時，要 `resets_at` 也改變或新值 ≤ 舊值一半才算重置；其他下降視為服務小幅下修，不算重置、該段消耗記 0
- 近期速度（「用得太快」、「約 N 分鐘後用完」、「可撐到星期幾」）改為回看範圍內相鄰兩筆正差值的總和 ÷ 時間，與額度消耗一致：回看範圍內有一次大幅下修時不再變成 0
- Token 數字改用「萬／億」三位有效數字（1,470萬、3.85億；不到一萬顯示整數），滑鼠移上去顯示完整數字
- 通知「剩不到 20%」預設開，第一次打開 App 時要求權限；系統設定關閉通知時，設定顯示「通知已在系統設定中關閉」與「打開系統設定」
- 文件：README 改為英文，原本的繁體中文版移到 `README.zh-TW.md`，兩者開頭互相連結；`scripts/check-readme-images.py` 也檢查 `README.zh-TW.md` 引用的圖片

### Added
- 角色的互動（ADR-0016）：瀏海面板展開時點角色會跳一下或揮手、連點 5 下轉暈、按住捏扁，滑鼠繞角色兩圈轉暈、快速左右甩動嚇到、停在角色上害羞；只處理瀏海面板自己視窗的滑鼠事件，不裝全域監聽。Claude 或 Codex 正在跑時角色低頭敲鍵盤：展開時每 5 秒看一次紀錄檔（`~/.claude/projects`、`~/.codex/sessions`）的修改時間，不開啟也不讀內容。設定新增「角色動畫」（完整／簡單／關閉；「減少動態效果」時完整當成簡單），選單列圖示新增「角色」與「角色＋%」
- Mac 瀏海面板與角色（ADR-0016）：滑鼠移到螢幕上方的瀏海會展開成 580×180 的面板，左邊是角色（Claude 或 Codex），右邊是兩個服務的額度，上方三個分頁（總覽、歷史開完整統計、設定開設定）；收合時瀏海兩旁顯示迷你角色與剩最少額度的迷你圓環。沒有瀏海的螢幕在選單列中間畫一個。第一次展開播約 4.7 秒的出場過場（可設為每次或關閉，「減少動態效果」時不播）。選單列圖示與原本的面板不變；設定可以關掉瀏海面板（預設開）
- 發布（ADR-0015）：推 `v*` tag 時另建置 Windows App 的自含式 zip（x64、ARM64，不需要安裝 .NET）與 `SHA256SUMS-windows`，放進草稿 Release；`scripts/package-windows-app.py` 檢查不含 .pdb、測試組件與 Debug 專用字串、組件版本等於 tag。新增 `docs/release-checklist.md`（第一次發布的檢查清單）
- 中繼的每月清理（ADR-0014 D-4）：Worker 加排程（每月 1 日 19:00 UTC），刪除第二層 400 天以前的每日加總（與上傳接受的範圍相同），每次最多 5,000 列（只佔 D1 免費方案每日寫入額度的一小部分，刪不完的留到下個月）；每台裝置最新的那一天保留，太久沒上傳的電腦不會被 Mac 當成「撤銷時已刪除資料」。要在部署設定加 `[triggers]` 並重新部署才生效（`setup-relay.sh` 新產生的設定已包含），見 relay/README.md
- `history.sqlite3` 的損毀復原與每週備份（ADR-0014 D-1）：連續約 1 小時寫不進去、而且 `quick_check` 也失敗時，收集器把舊檔改名為 `history.corrupt-<時間>.sqlite3` 保留（最多 2 份）並建立新檔，Mac 面板 7 天內提示；只是被鎖住時不動檔案。每 7 天以 SQLite 線上備份 API 複製一份到 `backups/`（通過 `quick_check` 才換上），只留最近 2 份；備份後空間不足時跳過，失敗只記日誌。設定的「清除歷史」連同備份與保留的舊檔一起刪除
- 偵測從別台電腦搬來的資料庫（ADR-0014 D-2）：第二層第一次上傳時記下這台電腦的硬體指紋雜湊（Mac 的 IOPlatformUUID、Windows 的 MachineGuid），之後不一致時暫停上傳（`upload_status = copied`），Mac 的統計卡片與完整統計視窗提示「歷史資料是從另一台電腦搬來的」；照 runbook 換新密鑰、重新執行 `set-tier2.sh`／`set-tier2.ps1` 後恢復。下載照常；讀不到指紋時不檢查
- 設定「歷史資料」顯示資料庫大小與預估（ADR-0014）：「資料庫 1.9 MB，依最近的使用量，保留 1 年時約維持在 6.4 MB」；永久保留時改說每年約增加多少，資料不滿 7 天時不估算。依各表佔用（SQLite `dbstat`）與收集器的清理規則推算：額度歷史 35 天後降為每小時一筆、每日統計隨保留期間刪除、每小時統計留保留期間與 90 天較短的一個、去重紀錄在收集器有時間窗時最多 90 天；個人紀錄不受保留期間影響，算在每年增加的部分（每年超過 1 MB 才另外顯示）（`HistorySize`）。截圖基準更新設定（淺色、深色）
- 含快取讀取的 Token 統計（v1.11，FR-60）：Mac 統計卡片與完整統計視窗在全部／Claude／Codex 旁加「含快取讀取」切換（預設關閉，記住選擇，面板與視窗共用）。打開時所有 Token 數字、Token 活動、熱力圖、各模型、時段與個人紀錄改用 input＋cache_write＋cache_read＋output，數字旁標「含快取」（滑鼠移上去說明）；這台 Mac、所有電腦與各電腦都適用。收集器另外記含快取讀取的單日最高與累計（`record_days_cached`、`best_day_tokens_cached`、`total_tokens_cached`，不受保留期間影響；同一個 schema 版本，升級時以 `seen_ids`／`file_tokens` 已計入的數值算出初始值，保留期間以前的快取讀取也算），舊版收集器沒有時 App 改由每日資料計算。VoiceOver 讀出切換狀態；截圖基準新增完整統計（含快取）與所有電腦（含快取）
- Codex 重置次數卷（v1.10，FR-58、FR-59，#94）：收集器從 `account/rateLimits/read` 讀可用張數與各張到期時間，寫進 `usage.json` 的選填欄位 `reset_credits`（同一個 `schema_version`；只讀、不使用卷，測試掃描收集器的程式碼確認）；Mac 面板的 Codex 額度卡片與 iPhone 主畫面顯示「重置卷 2 張 · 最早 11/20 到期」（0 張不顯示，Mac 滑鼠移上去列出每張）；Mac 通知「重置卷快到期」（3 天內到期，每張一次，預設開）。中繼要重新部署 iPhone 才看得到
- README 截圖：`scripts/update-readme-images.sh` 依 `docs/images/SOURCES.tsv` 以固定時間與示範資料重新產生（Mac 與動態島用 ImageRenderer，iPhone 主畫面、設定與手錶用模擬器截圖）；主要畫面有淺色、深色兩版，README 以 `<picture>` 依讀者的系統顯示；新增外觀設定的截圖，統計切換的 GIF 改為全部 → Claude → Codex → 全部。開頭一排是 Mac 面板的上半部（完整面板收在「看完整的 Mac 面板」）與 iPhone、下一排是動態島與手錶，同一排等高；統計 GIF 與完整統計視窗並排；畫面加上圓角與細邊框（`scripts/readme-image-post.swift`，SOURCES.tsv 第 5 欄）。`scripts/check-readme-images.py`（verify-all、CI）在 README 引用的圖不存在或沒有來源時失敗，比對應的截圖基準舊時提醒
- 外觀設定（v1.9，FR-51、FR-52，#81）：Mac 設定「外觀」可選跟隨系統（預設）、淺色、深色，套用到面板、設定、完整統計與設定精靈的視窗，以及匯出 CSV 的儲存對話框，選單列圖示仍跟隨選單列；iPhone 設定「外觀」只套用到 App 本身，Live Activity、小工具與手錶跟隨系統。切換有 0.3 秒過渡，減少動態效果時直接換
- Mac 一鍵安裝與內建收集器（v1.9，FR-53，ADR-0013，#83）：發布版 App 內嵌 Python（python-build-standalone 3.13 arm64，固定 SHA-256）與收集器，以 `SMAppService.agent` 註冊背景收集器；`scripts/build-release.sh` 產生 .zip、.dmg、寫好版本與 SHA-256 的一行安裝 `install.sh`（驗證 SHA-256、bundle ID、簽章；重跑即更新；`--uninstall`）；`.github/workflows/release.yml` 在 `v*` tag 只建立草稿 Release（附建置來源證明）。偵測到 `install-launchd.sh` 的舊收集器時**不註冊**，只提示，使用者按「改用內建收集器」才遷移；設定新增「背景收集器」
- 首次設定精靈（v1.9，FR-54，#84）：第一次打開、還沒有用量資料時顯示 8 個步驟（App 位置、背景收集器、Claude Code、Codex、通知、登入時開啟、外觀、在 iPhone 上看），每步顯示完成或要處理的事，需要指令時附「複製」；可從「設定 › 一般 › 重新執行設定精靈」再打開
- iPhone 配對與 `scripts/setup-iphone.sh`（v1.9，FR-55，ADR-0012，#85、#86）：Mac 終端機顯示 QR 碼（只含中繼網址與讀取密鑰，任何結束方式都清除畫面），iPhone 設定「從 Mac 配對 › 掃描 QR 碼」並確認主機名稱；輔助用中繼發的一次性短碼（`POST /pair`、`POST /pair/claim`：8 個字元、10 分鐘、錯 5 次作廢、只存雜湊，中繼要重新部署才有）。`setup-iphone.sh` 檢查 Xcode 與裝置、建置安裝、可選每 6 天自動重裝；`--dry-run`
- `scripts/setup-relay.sh`（v1.9，FR-56，#87）：登入 Cloudflare、建 KV、部署、產生並設定兩把密鑰、寫收集器設定；已有部署或設定就停止、不覆蓋；`--dry-run`；密鑰只經過標準輸入、wrangler 不寫磁碟日誌
- 建置與量測資料夾放 `.metadata_never_index`，不讓 Spotlight 索引（#72）；效能量測加上統計視窗第二次開關的 RSS 門檻，第一次打開多出的記憶體是系統一次性載入的程式碼與字型、不會累積（#80）
- `scripts/check-debug-env.py`（#79）：`"AUM_…"` 示範用環境變數只能出現在 `#if DEBUG` 裡（Swift 把短字串直接編進指令，Release 的 `strings` 檢查看不到），加進 verify-all 與 CI
- 第二層：多台電腦的 Token 合併（FR-49，ADR-0011 第 2、4 節；選用，預設關閉）。中繼新增 D1（`relay/migrations/0001_tier2.sql`，`wrangler.toml` 的綁定預設註解）與 `POST`／`GET /tokens/daily`、`/devices`（新增、列出、換新、撤銷，`ADMIN_TOKEN`）；每台電腦一把寫入密鑰（中繼只存 SHA-256、`device_id` 由中繼決定），以（裝置、日期、服務、模型）覆蓋寫入。`scripts/relay-device.sh` 管理裝置；`collector/scripts/set-tier2.sh`（Mac，Keychain）與 `collector/windows/set-tier2.ps1`（Windows 認證管理員）開啟或關閉。收集器 `token_sync`：只上傳本機有變動的每日加總（不含任務次數、每小時資料），每小時＋日期改變後，失敗遞增間隔重試，連續兩次 401 停止（403 來自 Cloudflare 邊緣，照一般失敗重試）；Mac 有讀取密鑰時下載其他電腦的加總（略過自己的所有 `device_id`）。`history.sqlite3` schema 3（`upload_state`、`devices`）。Mac 統計卡片與完整統計視窗：有其他電腦時標「所有電腦（N 台）」並可切換所有電腦／這台 Mac／各電腦，超過 48 小時沒有上傳標「N 天前更新」，密鑰失效時提示；說明見 `docs/tier2-setup.md`
- Windows 收集器（FR-48）：同一份 Python 程式，平台差異集中在 `usage_collector/system.py`；`collector/windows/install-task.ps1`／`uninstall-task.ps1` 以工作排程器每 5 分鐘統計 Token（預設不收集額度、不上傳；`-WithQuota` 只寫本機）；`--tokens-only`、`--log-file` 選項；CI 加 Windows runner；說明見 `docs/windows.md`
- 截圖比對：`scripts/snapshots.sh`（verify-all、CI）以固定時間與假資料產生 Mac 面板、完整統計、設定、選單列圖示與 iPhone 小工具、Live Activity、動態島，和 `apple/Snapshots/` 的基準比對；`scripts/update-snapshots.sh` 更新基準
- 對話紀錄格式改變的偵測（ADR-0009 第 9 節）：一次掃描中無法解析的行 ≥ 20%（至少 100 行），或新讀 4 MB 以上卻沒有任何 Token，統計卡片顯示「紀錄格式可能已改變，統計可能不完整」
- 「匯出 Token CSV」（設定 › 歷史資料，FR-37）：這台電腦的每日 Token，四種 Token 與推理分開、日期為本機日期；原來的按鈕改名「匯出額度 CSV」
- 服務狀態、通知、右鍵選單與快捷鍵（v1.8，FR-19、FR-45、FR-47，ADR-0008、ADR-0010 第四階段）。收集器在 `--write-local` 最後讀 Anthropic（status.claude.com）與 OpenAI（status.openai.com）的公開 Statuspage `summary.json`，只保留整體狀態、異常的元件名稱與未解決事件名稱（各最多 8 項、120 字），寫入本機 `service-status.json`（`0600`、不上傳、不帶任何密鑰或 cookie、至少間隔 4 分鐘）。Mac 面板新增「服務狀態」區塊：都正常時一行，異常或額度用完時變成卡片並分辨「服務異常，不是額度用完」與「額度已用完（服務正常）」，異常時橘點呼吸 3 次。設定新增「通知」（剩不到 20%、用得太快、額度重置，預設關，同一輪只通知一次，點通知打開面板並讓對應卡片亮一下）與「快捷鍵」（打開面板，預設不設定）；右鍵選單列圖示：立即更新、完整統計、設定、結束。`make-demo-history.py` 產生假的服務狀態，量測腳本加入橘點呼吸與卡片亮一下
- Mac 面板第三階段：統計卡片與完整統計視窗（v1.7，FR-43、FR-44、FR-46，ADR-0008～0011）。卡片標「這台 Mac」（滑鼠移上去說明不含網頁、手機 App、其他電腦與雲端 session），可切換全部／Claude／Codex：本週 Token（與上週同期比較 ▲▼%）、單日最高、最長任務、連續天數（創新紀錄時 🔥）、Token 活動（30 天／12 週／累計）與約 5 個月的活動熱力圖；主數字＝input＋cache_write＋output，滑鼠移到「本週 Token」看四種 Token 與快取讀取。首次掃描完成前顯示骨架「正在整理過去的紀錄（N%）」。頁尾「完整統計視窗 →」打開可調整大小的視窗（最小 720×520）：一年熱力圖、30 天疊加長條、各模型、一天中的時段、個人紀錄；打開時才讀資料庫、關閉時釋放。第三階段動畫：服務切換交叉淡入、數字滾動、長條依序長出、熱力圖逐欄淡入、🔥 每個新紀錄彈一次；減少動態效果時直接顯示。`make-demo-history.py` 產生假的 Token 資料，量測腳本加入統計切換與統計視窗
- 收集器 Token 統計（v1.7，FR-40～FR-44，ADR-0009）：讀這台 Mac 的 Claude Code 與 Codex CLI 對話紀錄（只列舉 ADR 列出的檔案、不跟隨符號連結、每行只取白名單欄位），把 `input`、`cache_write`、`cache_read`、`output`、`reasoning` 與任務時間分開累加到 `history.sqlite3`（schema 2：`daily_tokens`、`hourly_tokens`、`records`、`scan_state`、`seen_ids`、`seen_tasks`、`file_tokens`）。Claude 以訊息 ID 去重並補串流差額；Codex 每檔一種來源、改寫或換來源時先扣再重算；首次掃描每次最多 64 MB 或 15 秒並記錄進度；一般執行約增加 8 ms。`install-launchd.sh` 把 `CLAUDE_CONFIG_DIR`／`CODEX_HOME` 寫進 `config.json`；Mac App 支援 schema 2，「清除歷史」把 Codex 帳本歸零、「清除並重新掃描」一併清除任務去重與首次掃描狀態
- `scripts/codex-review.sh`：以 Codex（固定 `gpt-6.1-sol`、reasoning effort medium、唯讀）審查 `origin/main...HEAD` 的變更（`--diff`，預設）或整個 repo（`--full`），報告存到 `~/Documents/ai-usage-monitor-work/reviews/<分支>-codex.md`；模型無法使用或額度不足時印出原因並以非 0 結束，不改用其他模型。專案 skill `.claude/skills/codex-review` 說明何時跑與 triage 的寫法，CLAUDE.md 加上「開 PR 前先審查」
- `scripts/tests/`：shell 腳本的測試（以 `AUM_INSTALL_DIR` 與假 xcodebuild 跑完整的 `install-mac-app.sh` 流程、`codex-review.sh` 的參數與失敗處理、檢查沒有緊接非 ASCII 字元的 `$VAR`），接進 `verify-all.sh` 與 CI
- Mac 面板「接下來的重置」：重置時間已過、收集器還沒拿到新重置時間的額度，在「現在」的位置顯示圓點與「剛重置」；服務回報沒有重置時間（已用 0%、新一輪要等下次使用才開始）時，時間軸下方列「Codex 5h：已重置，下次使用時開始計時」
- `scripts/install-mac-app.sh`：Mac 選單列 App 以 Release 建置、結束執行中的 App、舊版本移到垃圾桶後安裝到「應用程式」並打開；設定新增「一般 › 登入時自動打開」（`SMAppService`，只在安裝於「應用程式」時可開啟）
- Mac 面板第二階段（FR-39～FR-42、FR-46，ADR-0008～0011）：讀 `history.sqlite3` 新增「建議接下來用」「接下來的重置」（8 小時時間軸與每週額度可撐到星期幾）「本週額度走勢」（剩餘 % 曲線、照時間的預期、可切換額度、沒有紀錄的時段畫斜線）「額度消耗」（每小時熱力圖與每日合計，標「整個帳號」，空檔平均分配並標估計）；歷史不足 2 筆時顯示骨架畫面；資料庫只在面板看得見時開啟。「用得太快」改為「照目前速度會在重置前用完」，「目前速度」、「約 N 分鐘後用完」與「可撐到星期幾」都用近期速度（每週額度要有 12 小時的樣本），不足時退回平均速度
- Mac 設定「歷史資料」（FR-37）：保留期間（7 天／30 天／90 天／1 年／永久）、匯出 CSV、清除歷史、清除並重新掃描，執行前確認
- Mac 第二階段動畫（ADR-0010）：走勢描繪與切換、建議滑入、時間軸圓點、重置圓點淡出、骨架掃光；Debug 截圖工具輸出對應 GIF；`scripts/make-demo-history.py` 產生假的額度歷史給截圖與效能量測
- 收集器寫入本機額度歷史 `history.sqlite3`（FR-37，ADR-0009）：每次收集一筆 `collector_runs`、每個額度一筆 `quota_samples`，只存時間、服務、額度 id、已用 % 與重置時間，不上傳；WAL、權限 `0600`；每天第一次執行時依保留期間（預設 1 年）刪除並把 35 天前的資料降為每小時一筆；鎖住、損毀或版本較新時只記日誌，不影響 `usage.json`、上傳與結束碼。`uninstall-launchd.sh` 詢問是否一併刪除（預設保留）
- iPhone 主畫面小工具（小／中／大）與鎖定畫面小工具（圓形／矩形／單行），kind `UsageHomeWidget`，放在既有的 `UsageWidget` 擴充；小工具自己以共用的 Keychain 讀取密鑰呼叫中繼，每 25 分鐘重新整理（資料過期時每小時），重置與過期時間點放在 timeline
- UsageKitUI `ProviderIcon`：原創服務圖示（Claude 八芒星、Codex 六瓣雲鏤空 `>_`），三個平台共用，template 繪製並套服務識別色，附 VoiceOver 名稱
- iOS／watchOS Debug 示範情境 `codex`（Codex 最吃緊）；手錶 `AUM_RENDER` 另輸出圓形複雜功能的淺色與主題色模擬
- 只用 Claude 或只用 Codex 的使用者：收集器 `config.json` 新增 `enabled_providers`，`install-launchd.sh` 依 Mac 上的登入資訊自動偵測並印出結果；未啟用的服務不出現在 `providers`、不算錯誤、不寫日誌。沒有這個欄位時全部啟用（舊安裝不變）
- 各平台在只有一個服務時不留空位（iPhone 大型小工具改放大最吃緊一項、額度單欄），沒有任何服務時顯示「沒有啟用任何服務」提示；Debug 示範情境 `claude-only`、`codex-only`、`none`
- `.claude/skills/ai-usage-monitor-design`：顏色、圖示定義、不收錄官方 logo、過期門檻、不能更改的識別字與 UI 驗證方式

### Changed
- 文件（v1.0，NFR-6）：README 改寫為功能、截圖與 Demo GIF（`docs/images/`，都是示範資料）、收集器／Mac App／中繼／iPhone 與手錶四段安裝步驟；隱私章節列出每個讀取的檔案與欄位、每個寫入的檔案（`history.sqlite3*`、`usage.json`、`service-status.json`、UserDefaults、Keychain）與網路請求，並說明離開 Mac 的使用者資料只有中繼快照。`docs/03-development-workflow.md` 里程碑表加入 v1.5～v2.0 與各里程碑的狀態；手動測試清單加入 v1.5、v1.6、v1.7（第 7～9 節），v1.8 改為第 10 節
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
- 完整統計視窗：打開時讀不到（history.sqlite3 還不存在、收集器正在建立）之後，檔案出現或變了會再讀一次，不再停在「無法讀取」直到關閉視窗
- 額度消耗（ADR-0009 第 4 節）：在午夜切換日光節約時間的時區（例如 America/Santiago、Havana），每天的格子改以各自的 startOfDay 起算；之前從切換日的 01:00 逐日加一天，其他天的 00:00～01:00 被算到前一天、切換日附近的小時重複計算。golden 新增 Santiago 兩個情境（切換日是今天、在範圍中間），Windows 的 UsageCore 原本就正確
- Windows 的 `install.ps1`：整個檔案包在一個 script block 裡，以 `irm | iex` 執行後不再在使用者的 PowerShell 工作階段留下 `$Zip`、`$Version` 等變數與安裝函式；CI 檢查 iex 前後變數不變
- 中繼 README：`POST /usage` 的大小上限更正為 64 KB（與程式的 `MAX_BODY_BYTES` 相同；原本寫 16 KB），並以測試檢查 README 與常數一致。中繼程式沒有改，不需要重新部署
- 完整統計視窗剛打開、還沒讀資料（視窗被擋住或 App 不在前景時要等視窗看得到才讀）時，顯示「正在讀取…」，不再顯示「無法讀取 Token 統計」；只有真的讀不到 history.sqlite3 時才顯示錯誤
- iPhone 設定的「掃描 QR 碼」在不能掃描時（沒有相機，例如模擬器）停用，文字與圖示改用次要顏色；之前文字仍是黑色、圖示是藍色，看起來像可以按。README 的設定截圖（淺色、深色）跟著更新
- `scripts/check-readme-images.py` 改比內容：`update-readme-images.sh` 把每張圖產生時基準的 SHA-256 記在 `docs/images/BASELINES.tsv`，基準內容改了才提醒。重新產生後圖片沒變時提交 BASELINES.tsv 就不再提醒（以前比提交時間，沒有東西可提交時提醒消不掉）；CI 不再需要完整的 git 歷史
- Windows 的 `install.ps1 -Uninstall`：收集器剛好在執行時，先等它停下（最多 30 秒）、刪除程式資料夾失敗時重試 15 秒，不再因「檔案正在使用」中斷；仍刪不掉時說明怎麼做（ADR-0014 LT-27，CI 偶發失敗發現）
- 長期使用的防護（ADR-0014）：Claude 的重置時間沒有年份時取前一年、今年、明年中離現在最近的一個，跨年不再算成 11 個月後或已過期（LT-10）；從鑰匙圈讀中繼寫入密鑰加 10 秒逾時，鑰匙圈卡住時不再拖住整次收集（LT-09）；系統時鐘往後跳時，清理每次最多前進 2 天（升級後第一次以上次清理的日期當基準），不會一次刪掉保留期間內的資料；時鐘倒退後降採樣的水位線重設，Token 同步的退避時間在未來太遠時視為過期（LT-11）；Codex 重新計算扣回 Token 後，單日最高與連續天數會跟著下修（LT-18）
- 第二層：撤銷並刪除資料（`relay-device.sh revoke --delete-data`）的電腦不再列在裝置切換、不算在「所有電腦（N 台）」裡，只剩這台 Mac 時回到「這台 Mac」；只撤銷、保留資料的電腦仍列出並標「已撤銷」、數字照算。中繼的 `GET /tokens/daily` 裝置清單加上 `has_data`（不限 `from`），收集器據此排除，**中繼要重新部署**才生效（舊版中繼照常列出）。截圖比對加上兩種情況的統計卡片
- 手錶 App 加上 App 圖示（與 iPhone 一般外觀相同的對角分色圖，`scripts/render-app-icon.sh` 一併產生）：錶面的即時動態提示與 App 列表原本顯示空白格子
- 改用 App 內建的收集器時，確認舊的 launchd 工作真的停止（最多等 3 秒）才算遷移完成；停不下來時放回舊的、撤回內建的。內建收集器除了舊的 plist，也問 `launchctl` 舊的工作在不在，無法確認時這一輪不收集，兩個收集器不會同時執行（Fable F-02，#89）
- 測試環境沒有指定 `AI_USAGE_MONITOR_HOME` 時，收集器、UsageKit 與 Mac App 的截圖／量測直接拒絕，不使用預設資料夾（#76、#78）
- night4 審查（#75）：貼圖造成的超長行不再觸發「紀錄格式可能已改變」；截圖比對另加「任一 32×32 格子超過 20% 不同就失敗」；萬／億改用整數四捨五入（99,950 顯示「10萬」）
- 總檢查（night3 第 8 部分，修正 commit 的 Codex 審查與 Fable 對抗式審查）：
  - Token 統計：跨過保留期間邊界的那一週不再當成完整的一週；縮短保留期間後再延長，已刪除的日子仍標「超過保留期間」而不是 0（App 記在 `meta.token_days_from`）；同一個 Codex rollout 被複製到 `archived_sessions` 時只算一次；完整統計視窗的「各模型」把兩家的 `other` 分開、各用自己的顏色
  - 額度：每週額度沒有近期速度時，經過 10% 以前不預測「可撐到星期幾」（與「用得太快」同一規則）；資料過期時時間軸不再把早已過去的重置標成「剛重置」
  - 文件：README 隱私章節補上 `menuBar.*`、登入項目、stderr、狀態頁與 `launchctl kickstart`，Codex 讀取欄位改為實際的 `task_complete`；ADR-0008 決定 1 註明 v1.6 的規則；ADR-0009 註明 CSV 尚未匯出每日 Token
- 收集器連上中繼或狀態頁後讀取回應逾時（`TimeoutError`）、連線被中斷或回應不完整時，整個收集器中斷並在日誌留下 traceback，之後的額度歷史、Token 統計與服務狀態都沒有寫入；改為回報「網路錯誤（連線逾時或中斷）」並照常執行後續步驟
- 手錶：iPhone 傳來的設定存不進 Keychain 時，錯誤改為獨立顯示（未設定時也看得到、抓取成功不會洗掉）；套用新設定後，用舊密鑰開始的抓取結果不再蓋過新的結果；背景更新的第一次排程要求改為直接送出（在背景工作結束前），失敗時才延後重試（整合審查 D-a、D-b、D-c）
- `reinstall-ios.sh`：接手殘留的鎖時，若改名到的是別人的新鎖而且又放不回去，保留原樣並記錄，不再 `rm -rf`（整合審查 D-h 3-2）
- 共用 fixture 新增「只有 Codex、plan 為 null、已用超過 100%」與「沒有任何服務」兩種，收集器、中繼與 UsageKit 的測試一起讀（整合審查 D-i）
- 動態島展開後最下方被切掉、左上第一個字被圓角切到：展開版面改為只放剩餘最少的額度、各服務一行的 % 與細進度條、一行更新時間，更新按鈕移到右上，各額度不再顯示重置時間；左右與上下加內距，總高約 150pt（系統上限約 160pt）。鎖定畫面卡片不變。Debug 版 `AUM_RENDER=1` 以 ImageRenderer 輸出近似版面
- `scripts/install-mac-app.sh` 安裝完成後中斷、沒有打開 App：`$DEST（` 在 macOS 的 bash 3.2（UTF-8 locale）會把全形括號當成變數名稱的一部分，`set -u` 下變成「unbound variable」。所有 shell 腳本中緊接非 ASCII 字元的變數改為 `${VAR}`
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

### Removed
- Mac 桌面小工具（FR-24 改為不做）：移除 `UsageDesktopWidget` 擴充、App Group 快照複本與 25 分鐘 reload 節流（`WidgetReloadThrottle`）、`project.team.yml` 與 `*.team.entitlements`；Mac 選單列 App 不再需要 Team 簽署。iPhone 主畫面／鎖定畫面小工具與手錶複雜功能不受影響

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
