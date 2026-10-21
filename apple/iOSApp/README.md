# iOS App

讀取[中繼 API](../../relay/) 並顯示 Claude 與 Codex 的剩餘額度。資料模型、解析與顏色規則來自 [UsageKit](../UsageKit/)。

| 畫面 | 內容 |
|---|---|
| 主畫面 | 最吃緊的一項額度、各服務的所有額度（剩餘 %、進度條、重置倒數）、最後更新時間；超過 30 分鐘未更新提示 Mac 可能已關機；下拉或回到前景時重新整理 |
| 設定 | 中繼網址與讀取密鑰、測試連線、顯示「已用 %」或「剩餘 %」 |
| Live Activity（鎖定畫面） | 最吃緊的一項大字顯示、各服務各額度的進度條與重置倒數、更新時間與「更新」按鈕；過期資料轉灰並標示「資料已過期」；單一服務失敗只在該列顯示錯誤；重置時間已過顯示「已重置」 |
| 動態島 | 精簡：服務圖示 + 最吃緊的百分比；展開：與鎖定畫面相同的內容 |
| 主畫面小工具 | 小：最吃緊的一項大字（服務圖示、%、進度條、重置倒數、更新時間）；中：與 Live Activity 卡片相同的版面；大：最吃緊的一項 + 每個服務的所有額度。中、大有「更新」按鈕 |
| 鎖定畫面小工具 | 圓形（容量環 + 服務圖示 + %）、矩形、單行，與手錶複雜功能共用 UsageKitUI 的 `ComplicationView`（過期門檻改用 iPhone 的 30 分鐘） |

主畫面的「Live Activity」區塊可開始、更新、結束卡片。卡片上的「更新」按鈕是 `RefreshUsageIntent`（LiveActivityIntent），由系統在 App 程序中執行，不需要打開 App。Live Activity 最長顯示 8 小時，之後可從 App 或下方的捷徑重新開始。

配對的 Apple Watch 會在智慧型堆疊顯示同一張卡片，使用手錶專用的精簡版面（`WatchActivityView`，只顯示最吃緊的一項，FR-27）。這需要 `supplementalActivityFamilies`（iOS 18 API），所以 Widget 擴充的最低支援是 iOS 18；App 本身仍可在 iOS 17 執行，但不會出現 Live Activity。

## 捷徑：讓卡片整天顯示

Live Activity 最長 8 小時。App 提供捷徑動作「重新啟動用量監看」（`RestartUsageActivityIntent`），會抓最新資料、開一張新卡片，成功後才結束舊卡片（抓資料或開卡失敗時舊卡片保留），不需要打開 App。安裝 App 後就會出現在捷徑 App，也可以對 Siri 說「重新啟動 AI 用量」。

設定定時自動化（在 iPhone 上操作，與 [ADR-0002](../../docs/adr/0002-shortcut-restart-live-activity.md) 相同為 3 個、間隔 ≤ 8 小時）：

1. 打開「捷徑」App →「自動化」→ 右上角「+」（還沒有任何自動化時是「新增自動化」按鈕）
2. 選「特定時間」07:00，重複「每天」，選「立即執行」，並關閉「執行時通知」（否則每次都會跳出橫幅）
3. 加入動作「重新啟動用量監看」
4. 以相同方式建立 15:00 與 23:00 兩個自動化，三張卡片接力即可整天顯示

即使從多工畫面關閉 App，自動化仍會在背景執行。重新開機後尚未解鎖前，Keychain 中的讀取密鑰無法讀取，該次自動化會失敗、舊卡片保留，解鎖後下一次自動化即恢復。iOS 17 不支援（Widget 擴充需要 iOS 18），捷徑會回報「Live Activity 需要 iOS 18 以上」。

讀取密鑰存在 iPhone 的 Keychain（`AfterFirstUnlockThisDeviceOnly`），網址與顯示模式存在 App Group 的 UserDefaults（舊版存在 App 自己的 UserDefaults，第一次啟動時複製過來）。儲存設定時會以 WatchConnectivity 的 application context 傳給已安裝的 [Apple Watch App](../WatchApp/)；系統會在 iPhone 與手錶各保留最後一份 context（不在 Keychain），詳見[隱私與安全](../../README.md#隱私與安全)。

## 主畫面與鎖定畫面小工具

小工具（kind `UsageHomeWidget`）放在既有的 `UsageWidget` 擴充裡，與 Live Activity 同一個 bundle，不需要新的 App ID（免費 Apple ID 每 7 天最多建立 10 個）。長按主畫面 →「編輯」→「加入小工具」→「AI 用量」，或長按 App 圖示直接選尺寸。

小工具自己呼叫中繼，不必等 App 開啟：

- **網址與顯示模式**：App Group `group.io.github.kevin930326.AIUsageMonitor` 的 UserDefaults
- **讀取密鑰**：仍只在 Keychain。App 與擴充的 `keychain-access-groups` 都是 App 自己的 application identifier（`<Team ID>.io.github.kevin930326.AIUsageMonitor`），也就是舊版寫入密鑰時的預設群組，所以不用搬移，小工具直接讀得到
- **最後一份資料**：App Group 的 `usage.json`。小工具抓不到中繼（沒網路、重新開機後尚未解鎖讀不到 Keychain）時顯示這份，畫面依資料時間轉灰

免費 Apple ID（Personal Team）的佈建描述檔也包含 App Group 與 Keychain 共享（已用 `-allowProvisioningUpdates` 實際簽署確認），兩項都寫在 `project.yml` 的 entitlements。

### 重新整理次數

WidgetKit 每個小工具每天約 40～70 次重新整理。Timeline 中預先排好的時間點不扣次數，所以重置與資料過期（30 分鐘）的時間點都放在 timeline 裡，讓「已重置」與轉灰準時出現；重置倒數用 `Text(date, style: .relative)` 由系統自己數。

| 來源 | 次數／天 | 說明 |
|---|---|---|
| 小工具自己排程（資料新） | 最多 58 | 每 25 分鐘。收集器每 5 分鐘上傳，抓到的資料最多 5 分鐘舊，25 分鐘後重新整理時還沒超過 30 分鐘門檻，兩次之間不會誤顯示「已過期」 |
| 小工具自己排程（資料已過期） | 每小時 1 | Mac 關機或睡眠時放慢；例如每晚 8 小時可省下約 11 次 |
| App 在背景取得新資料 | 約 5 | 捷徑「重新啟動用量監看」每天 3 次、卡片上的「更新」 |
| App 在前景、小工具上的「更新」按鈕 | 不扣 | WidgetKit 不計算 App 在前景與按鈕 Intent 觸發的重新整理 |

一般情況（Mac 每晚睡 8 小時）約 38 + 8 + 5 ≈ 51 次；Mac 整天開著最多約 63 次。超過預算時系統會延後更新，畫面會依資料時間轉灰並顯示「資料已過期」，不會顯示錯誤的數字。

## 建置

Xcode 專案由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 產生，`.xcodeproj` 不進版控。

```bash
brew install xcodegen
cd apple/iOSApp
xcodegen generate
open AIUsageMonitor.xcodeproj
```

在模擬器執行不需要簽署。裝到自己的 iPhone：在 Xcode 的 Signing & Capabilities 選自己的 Team（免費 Apple ID 即可），或執行 `DEVELOPMENT_TEAM=XXXXXXXXXX xcodegen generate`。

命令列建置：

```bash
xcodebuild -project AIUsageMonitor.xcodeproj -scheme AIUsageMonitor \
  -destination 'platform=iOS Simulator,name=<模擬器名稱>' build
```

## 每週自動重新安裝（免費 Apple ID）

以免費 Apple ID（Personal Team）簽署的 App 7 天後就無法開啟。`scripts/reinstall-ios.sh` 會重新簽署並透過網路裝到 iPhone，搭配 launchd 在滿 6 天後自動執行。

第一次設定：

1. 在 Xcode → Settings → Accounts 登入 Apple ID，並用 Xcode 把 App 裝到 iPhone 一次（手機會詢問是否信任這台 Mac）。
2. 在 Xcode 的 Devices and Simulators 視窗勾選該 iPhone 的「Connect via network」，之後不必接線。
3. 手機在旁邊並解鎖，先手動執行一次：
   ```bash
   scripts/reinstall-ios.sh
   ```
   第一次執行會偵測 Team ID 與 iPhone，寫入 `~/Library/Application Support/AIUsageMonitor/config.json` 的 `development_team` 與 `iphone_udid`（合併寫入，不會動到收集器的 `relay_url`、`claude_path`；不進版控）。連過多台 iPhone 或登入多個 Team 時不會自動選，請手動把值寫進 config.json。
4. 安裝排程：
   ```bash
   scripts/install-reinstall-launchd.sh
   ```

排程的運作方式：

- 每 20 分鐘檢查一次，依距上次成功的時間決定要不要重新建置與安裝：

  | 距上次成功 | 何時安裝 | 裝完 |
  |---|---|---|
  | 未滿 6 天 | 不安裝（檢查不到 1 秒就結束） | — |
  | 6～6.5 天 | 只在捷徑自動化前的時段：06:35～06:55、14:35～14:55、22:35～22:55 | 不打開 App，卡片由接著的 07:00／15:00／23:00 捷徑開回來，最多約 25 分鐘 |
  | 滿 6.5 天，或從未成功 | 不挑時間 | 打開 App（帶 `--start-live-activity` 參數），由 App 在前景把卡片開回來 |

  重新安裝會結束鎖定畫面的 Live Activity 卡片，所以平常排在捷徑前、讓捷徑接手；簽署快到期時以裝成功為優先。失敗時下一次符合條件的檢查就會重試，直到成功為止。手動執行 `scripts/reinstall-ios.sh` 一律立即安裝並打開 App。
- 時段寫在 `scripts/reinstall-ios.sh` 的 `SHORTCUT_TIMES`，要與上面「捷徑：讓卡片整天顯示」的自動化時間相同；改了自動化時間要一起改。
- 安裝成功時發 macOS 通知；同一輪連續失敗超過 1 天時再通知一次（不會每次重試都通知）。
- 簽署使用 Xcode 已登入的 Apple ID（`xcodebuild -allowProvisioningUpdates`），腳本內沒有帳號或密碼。建置的是 Release（不含示範模式）。

限制：

- 手機要與 Mac 在同一個網路，且是醒著的；長時間鎖定或休眠時安裝可能失敗，會在下一個時段重試。
- Mac 睡眠時排程不會執行，醒來後只補一次檢查：不在時段內且未滿 6.5 天時略過，等下一個時段。滿 6 天到 7 天之間 Mac 一直睡著或關機時，簽署會過期，Mac 醒來後才補裝；連續失敗超過 1 天會通知。
- 快到期時安裝成功但手機鎖定，打不開 App，鎖定畫面卡片會暫時消失，要等下一次捷徑自動化或手動打開 App；通知會提醒。
- 腳本只重新安裝 iPhone App，手錶 App（`apple/WatchApp`）仍需用 Xcode 手動安裝。
- Xcode 的 Apple ID 登入過期時建置會失敗，需要重新登入。
- repo 在 `~/Documents` 時，排程透過與收集器相同的 `python3` 啟動腳本，沿用它存取「文件」資料夾的權限（launchd 直接執行 bash 會被 macOS 隱私保護拒絕）。沒有安裝過收集器排程時，macOS 可能會詢問是否允許 python3 存取「文件」。

查看日誌：

```bash
tail -n 20 ~/Library/Logs/AIUsageMonitor/reinstall.log        # 每次執行的結果
tail -n 50 ~/Library/Logs/AIUsageMonitor/reinstall-build.log  # 最近一次 xcodebuild 的完整輸出
```

結束碼：0 成功或還不需要、1 建置失敗、2 找不到手機、3 安裝失敗、4 設定錯誤。上次成功與失敗的時間記在 `~/Library/Application Support/AIUsageMonitor/reinstall-state.json`。

移除排程（不會刪除設定與日誌）：

```bash
scripts/uninstall-reinstall-launchd.sh
```

排程執行的是安裝時所在資料夾裡的腳本；搬移 repo 後要重新執行 `scripts/install-reinstall-launchd.sh`。

## 開發用：預先填入設定

模擬器的文字輸入不太穩定。Debug 版本會讀取下列環境變數，覆寫設定（只存在記憶體，不寫入 Keychain）：

```bash
SIMCTL_CHILD_AUM_RELAY_URL=ai-usage-relay.<帳號>.workers.dev \
SIMCTL_CHILD_AUM_READ_TOKEN="$(security find-generic-password -s AIUsageMonitor-relay-read -w)" \
xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
```

密鑰從 Mac 的 Keychain 讀出後直接傳給 App，不會出現在畫面或 shell 歷史紀錄。Release 版本不包含這段程式。

## 開發用：示範模式

Debug 版本以 `AUM_DEMO=<情境>` 啟動時只使用假資料、完全不連網，並自動開始一張 Live Activity，方便截圖與檢查版面：

| 情境 | 內容 |
|---|---|
| `normal` | 兩個服務都正常 |
| `stale` | 45 分鐘前的資料（灰色、資料已過期） |
| `error` | Codex 失敗、Claude 正常 |
| `reset` | Claude 5 小時額度的重置時間已過 |
| `used` | 顯示已用 % |
| `codex` | Codex 最吃緊（動態島顯示 Codex 圖示） |
| `claude-only` | 只用 Claude（收集器沒有啟用 Codex，`providers` 只有 `claude`） |
| `codex-only` | 只用 Codex |
| `none` | 收集器沒有啟用任何服務（顯示「沒有啟用任何服務」提示） |

另外設定 `AUM_DEMO_ACTION=restart` 時，開卡一秒後會再執行一次捷徑動作，並把前後的卡片 ID 寫到 `Documents/restart-log.json`。

```bash
SIMCTL_CHILD_AUM_DEMO=normal xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
```

示範情境也會寫進 App Group，主畫面／鎖定畫面小工具同樣只顯示假資料（以非示範模式重新啟動 App 即恢復）。截圖見 [`docs/screenshots/ios-widget/`](../../docs/screenshots/ios-widget/)；單一服務與沒有服務的情境見 [`docs/screenshots/single-provider/`](../../docs/screenshots/single-provider/)。

情境存在 Live Activity 的屬性中，所以按卡片上的「更新」也會使用同一份假資料。每次開始、更新、結束卡片都會寫入 App 容器的 `Documents/activity-log.json`（只有 Debug 版本）。
