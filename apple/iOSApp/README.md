# iOS App

讀取[中繼 API](../../relay/) 並顯示 Claude 與 Codex 的剩餘額度。資料模型、解析與顏色規則來自 [UsageKit](../UsageKit/)。

| 畫面 | 內容 |
|---|---|
| 主畫面 | 最吃緊的一項額度、各服務的所有額度（剩餘 %、進度條、重置倒數）、最後更新時間；超過 30 分鐘未更新提示 Mac 可能已關機；下拉或回到前景時重新整理 |
| 設定 | 中繼網址與讀取密鑰、測試連線 |

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
