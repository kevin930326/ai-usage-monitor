# Apple Watch App

在手錶上查看 Claude 與 Codex 的剩餘額度。資料模型與顏色規則來自 [UsageKit](../UsageKit/)，Keychain 存取與 Debug 示範資料直接共用 iOS App 的 `Shared/` 檔案。

| 部分 | 內容 |
|---|---|
| 手錶 App | 最吃緊的一項大字顯示，各服務各額度的進度條與重置倒數、更新時間；過期轉灰、重置後顯示「已重置」（FR-29） |
| 錶面複雜功能 | 圓形（容量環 + %）、矩形（名稱 + % + 進度條）、單行（名稱 + %），顯示最吃緊額度的剩餘 % 與分級顏色（FR-28） |
| 設定同步 | iPhone App 儲存中繼設定時，以 WatchConnectivity 的 application context 傳到手錶，手錶不需要輸入（FR-30） |

手錶直接呼叫中繼 API（UsageKit `RelayClient`），讀取密鑰存在手錶的 Keychain（WatchConnectivity 也會保留最後一份 application context）。複雜功能透過 App Group（`group.io.github.kevin930326.AIUsageMonitor`，已寫在 `project.yml` 的 entitlements）讀取手錶 App 存下的最後一份資料；實機需以 Team 簽署，未簽署時複雜功能顯示「--」。

## 建置

```bash
cd apple/WatchApp
xcodegen generate
xcodebuild -project AIUsageWatch.xcodeproj -scheme AIUsageWatch \
  -destination 'platform=watchOS Simulator,name=<手錶模擬器名稱>' build
```

手錶 App 設定為可獨立執行（`WKRunsIndependentlyOfCompanionApp`），模擬器不需要配對 iPhone 也能安裝。裝到實機時需在 Xcode 為兩個 target 選 Team，並加入上述 App Group。

## 開發用

Debug 版本支援：

| 變數 | 作用 |
|---|---|
| `AUM_DEMO=<情境>` | 使用假資料、不連網，情境與 iOS 相同（`normal`、`stale`、`error`、`reset`、`used`） |
| `AUM_RENDER=1` | 把三種複雜功能以 ImageRenderer 輸出到 App 容器的 `Documents/complication-*.png` |

```bash
SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER=1 \
  xcrun simctl launch <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp
xcrun simctl get_app_container <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp data
```

## 尚未驗證

- WatchConnectivity 實際傳輸需要配對的 iPhone 與 Apple Watch（模擬器配對未測試）
- 複雜功能實際加到錶面需要 App Group 簽署
