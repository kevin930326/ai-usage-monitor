# iOS App

讀取[中繼 API](../../relay/) 並顯示 Claude 與 Codex 的剩餘額度。資料模型、解析與顏色規則來自 [UsageKit](../UsageKit/)。

| 畫面 | 內容 |
|---|---|
| 主畫面 | 最吃緊的一項額度、各服務的所有額度（剩餘 %、進度條、重置倒數）、最後更新時間；超過 30 分鐘未更新提示 Mac 可能已關機；下拉或回到前景時重新整理 |
| 設定 | 中繼網址與讀取密鑰、測試連線、顯示「已用 %」或「剩餘 %」 |
| Live Activity（鎖定畫面） | 最吃緊的一項大字顯示、各服務各額度的進度條與重置倒數、更新時間與「更新」按鈕；過期資料轉灰並標示「資料已過期」；單一服務失敗只在該列顯示錯誤；重置時間已過顯示「已重置」 |
| 動態島 | 精簡：服務字首 + 最吃緊的百分比；展開：與鎖定畫面相同的內容 |

主畫面的「Live Activity」區塊可開始、更新、結束卡片。卡片上的「更新」按鈕是 `RefreshUsageIntent`（LiveActivityIntent），由系統在 App 程序中執行，不需要打開 App。Live Activity 最長顯示 8 小時，之後需要從 App 重新開始。

配對的 Apple Watch 會在智慧型堆疊顯示同一張卡片，使用手錶專用的精簡版面（`WatchActivityView`，只顯示最吃緊的一項，FR-27）。這需要 `supplementalActivityFamilies`（iOS 18 API），所以 Widget 擴充的最低支援是 iOS 18；App 本身仍可在 iOS 17 執行，但不會出現 Live Activity。

讀取密鑰存在 iPhone 的 Keychain（`AfterFirstUnlockThisDeviceOnly`），網址存在 UserDefaults。

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

```bash
SIMCTL_CHILD_AUM_DEMO=normal xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
```

情境存在 Live Activity 的屬性中，所以按卡片上的「更新」也會使用同一份假資料。每次開始、更新、結束卡片都會寫入 App 容器的 `Documents/activity-log.json`（只有 Debug 版本）。
