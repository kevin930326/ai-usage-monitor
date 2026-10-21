---
name: ai-usage-monitor-design
description: AI Usage Monitor 的設計與識別規則：服務識別色、原創服務圖示（Claude 八芒星、Codex 六瓣雲）的精確定義、不收錄官方 logo、各平台資料過期門檻、不能更改的識別字（Bundle ID、App Group、小工具 kind、Keychain），以及 UI 驗證方式。修改 apple/ 下任何畫面、顏色、圖示、Live Activity、小工具、錶面複雜功能、Info.plist／project.yml 識別字，或新增服務時先讀這份。
---

# AI Usage Monitor 設計規則

修改 iPhone、Live Activity、Mac、Apple Watch 任何畫面前先讀完。規則的程式來源寫在每節最後，兩邊不一致時以程式為準並回頭更新這份文件。

## 1. 顏色（FR-16）

| 用途 | 深色外觀 | 淺色外觀 |
|---|---|---|
| Claude 識別色 | `#D97757` | `#B4532F` |
| Codex 識別色 | `#5CC2B1` | `#237A6B` |
| 剩餘 < 20% 的進度條（critical） | `#FF453A` | `#D70015` |
| 提示文字（資料已過期、服務錯誤） | `#FF9F0A` | `#A65200` |
| 資料過期時的進度條 | 系統灰色 `Color.gray` | 同左 |

- 進度條：一般為服務識別色；剩餘 < 20% 改紅色；資料過期一律灰色（灰色優先於紅色）。
- **文字一律 primary／secondary**，不用顏色表示狀態；顏色只用在進度條、服務圖示與提示文字。文字對比度 ≥ 4.5:1，圖形 ≥ 3:1（`UsagePaletteTests` 會檢查）。
- 黑底場合（動態島、手錶錶面）固定用深色值：`UsageColors.providerMark(_:)`。
- 不要在畫面裡寫死色碼，一律用 `UsageColors`（SwiftUI）或 `UsagePalette`（數值）。

來源：`apple/UsageKit/Sources/UsageKit/UsagePalette.swift`、`apple/UsageKit/Sources/UsageKitUI/UsageColors.swift`。

## 2. 服務圖示

動態島精簡版與圓形錶面複雜功能用圖示區分服務（空間不夠放名稱）。兩個圖示都是**原創**，定義在 `viewBox 0 0 24 24`，實作為 UsageKitUI 的 `ProviderIcon`（`ClaudeIconShape`、`CodexIconShape`），三個平台共用。

### Claude：八芒星

長短交錯的八芒星，實心填色，另加 **0.7 寬、圓角接合（round join）** 的同色描邊：

```
M12.00 1.00 L13.65 8.03 L17.80 6.20 L15.97 10.35 L23.00 12.00 L15.97 13.65 L17.80 17.80 L13.65 15.97
L12.00 23.00 L10.35 15.97 L6.20 17.80 L8.03 13.65 L1.00 12.00 L8.03 10.35 L6.20 6.20 L10.35 8.03Z
```

### Codex：六瓣圓雲，中間鏤空 `>_`

- 實心形狀是 7 個圓的聯集：中心圓 (12,12) 半徑 8.0；6 個外圓半徑 4.0，圓心
  (12.00,5.00)、(18.06,8.50)、(18.06,15.50)、(12.00,19.00)、(5.94,15.50)、(5.94,8.50)。
- 以筆劃 `M8 9l3 3-3 3M12.6 15.2h3.8`（線寬 2.3、圓頭、圓角）挖空，**鏤空處透出背景**（不是畫上背景色）。

### 繪製規則

- 圖示是單一 `Shape`，以目前的 `foregroundStyle` 填色（template）。全彩時套 `UsageColors.providerMark`，資料過期時套灰色。
- 錶面上加 `.widgetAccentable()`，讓單色／主題色錶面由系統換色；鏤空要維持透明。
- 只有圖示、沒有文字的地方要有 `accessibilityLabel`（「Claude」「Codex」）。`ProviderIcon` 已內建，不要拿掉。
- 目前尺寸：動態島精簡版 18pt、圓形複雜功能 13pt。縮小前要重新驗證（見第 8 節）。
- 新增服務時要設計新的原創圖示並寫進本節；`ProviderIcon` 對未知服務暫時畫圓形。

### App 圖示

兩個服務圖示沿對角線分開。座標用 100×100 畫布；輸出 1024×1024，**不透明、不加圓角**（系統自己裁圓角）。

| | 一般 | 深色（iOS 18） | 主題色（iOS 18） |
|---|---|---|---|
| 背景 | 青綠 `#5CC2B1`；左上三角 (0,0)-(100,0)-(0,100) 珊瑚橘 `#D97757` | `#000` | `#000` |
| 分隔線 (100,0)→(0,100)，寬 2.5 | 白色 | `#2A2A2C` | `#3A3A3A` |
| 八芒星 `ClaudeIconShape`，translate(8,8) scale(1.95) | 白色 | `#D97757` | `#E6E6E6` |
| 六瓣雲 `CodexIconShape`，translate(48,48) scale(1.85) | 白色 | `#5CC2B1` | `#A8A8A8` |
| 陰影（兩個圖示） | 向下 1.5、模糊半徑 1.6、黑色 28% | 無 | 無 |

- 雲朵的 `>_` 鏤空透出底下的背景（一般為青綠，深色與主題色為黑色）。
- Mac 選單列 App 用一般外觀：1024 畫布中置中 824×824、連續圓角半徑 22.5%（約 185），加向下 10、模糊 10、黑色 30% 的陰影，四周透明；輸出 16～1024 各尺寸。
- 手錶 App 尚未加圖示。
- **不要手改 PNG**：改 `scripts/render-app-icon.swift` 後執行 `scripts/render-app-icon.sh`，它直接用 UsageKitUI 的兩個 Shape，圖示會和 App 內一致。

來源：`scripts/render-app-icon.swift`、`apple/iOSApp/AIUsageMonitor/Assets.xcassets/AppIcon.appiconset`、`apple/MacMenuBar/AIUsageMenuBar/Assets.xcassets/AppIcon.appiconset`、兩個 `project.yml` 的 `ASSETCATALOG_COMPILER_APPICON_NAME`。

## 3. 不收錄官方 logo

repo 內**不收錄** Anthropic、Claude、OpenAI、Codex 的官方 logo、商標圖或其描摹，包括 SVG、PNG、SF Symbols 以外的圖片資源。上面兩個圖示是原創造型，不要改成接近官方 logo 的形狀。

## 4. 資料過期門檻（FR-11）

| 平台 | 門檻 | 常數 |
|---|---|---|
| iPhone App、Live Activity、Mac 選單列與桌面小工具 | 30 分鐘 | `UsageSnapshot.staleAfter` |
| Apple Watch App 與錶面複雜功能 | 45 分鐘 | `UsageSnapshot.watchStaleAfter` |

手錶較長是因為背景重新整理約每 30 分鐘一次，且時間由 watchOS 決定（見 `apple/WatchApp/README.md`）。Timeline 的重新整理時間點要用和畫面相同的門檻。

## 5. 不能更改的識別字

改了會讓已安裝的 App 失去資料、Keychain 中的密鑰、使用者已加入的小工具與錶面複雜功能，或讓收集器找不到密鑰。

| 類別 | 值 |
|---|---|
| iOS App Bundle ID | `io.github.kevin930326.AIUsageMonitor` |
| Live Activity 擴充 | `io.github.kevin930326.AIUsageMonitor.UsageWidget` |
| Mac 選單列 App | `io.github.kevin930326.AIUsageMenuBar` |
| Mac 桌面小工具 | `io.github.kevin930326.AIUsageMenuBar.UsageDesktopWidget` |
| watchOS App | `io.github.kevin930326.AIUsageMonitor.watchkitapp` |
| 錶面複雜功能 | `io.github.kevin930326.AIUsageMonitor.watchkitapp.UsageComplications` |
| App Group | `group.io.github.kevin930326.AIUsageMonitor` |
| 小工具 kind | Mac `UsageDesktopWidget`、手錶 `UsageComplication` |
| iOS／watchOS Keychain | service `io.github.kevin930326.AIUsageMonitor`，account `relay-read-token` |
| Mac Keychain（收集器） | 寫入密鑰 service `AIUsageMonitor-relay-write`，account `default`；讀取密鑰 service `AIUsageMonitor-relay-read` |

另外：本機快照路徑 `~/Library/Application Support/AIUsageMonitor/usage.json` 與環境變數 `AI_USAGE_MONITOR_HOME` 由收集器與 `UsageFileLocator` 共用，兩邊要一起改。

## 6. 資訊排列

所有平台（iPhone App、Live Activity、Mac 面板與桌面小工具、手錶 App 與複雜功能）都遵守：

- **最吃緊的一項永遠放在最顯眼的位置**（FR-15）：所有服務的可見額度中剩餘最少的一項；排除 `hidden` 額度與有錯誤的服務；同分時取較早重置的；已重置的額度視為剩餘 100%。一律用 `UsageSnapshot.tightestWindow(at:)`（Live Activity 用 `UsageActivityState.tightest(at:)`），不要自己挑。
  來源：`apple/UsageKit/Sources/UsageKit/UsageWindow+Reset.swift`（`tightestWindow(at:)`）、`UsageActivityState.swift`（`tightest(at:)`）。
- **服務順序固定**：Claude、Codex，其他服務依名稱排序。用 `orderedProviderKeys`，不要直接走訪 `providers` 字典（字典沒有順序）。
  來源：`apple/UsageKit/Sources/UsageKit/UsageSnapshot+Display.swift`（`knownProviderOrder`、`orderedProviderKeys`）。
- **每個額度顯示**：名稱、剩餘或已用 %（依使用者設定，FR-17，預設剩餘）、進度條、依 `resets_at` 計算的重置倒數（用 `Text(date, style: .relative)` 讓系統自己倒數，不必重新抓資料）。
  來源：`apple/UsageKit/Sources/UsageKitUI/UsageWindowRow.swift`、`UsageWindow+Reset.swift`（`UsageDisplayMode`、`displayedPct`）。
- **重置時間已過**（FR-26）：顯示「已重置」，百分比顯示剩餘 100%（已用模式為 0%）。Mac 離線時資料停在重置前，舊數字已不正確。
  來源：`UsageWindow+Reset.swift`（`isReset`、`effectiveUsedPct`）、`UsageWindowRow.swift`。
- **單一服務失敗只影響該服務**（FR-12）：該服務顯示錯誤訊息，其他服務照常顯示；最吃緊的一項從正常的服務中挑。Live Activity 的錯誤訊息截短到 60 字以控制大小。
  來源：`collector/usage_collector/__main__.py`（`collect()`）、`apple/iOSApp/Shared/ActivityViews.swift`、`apple/MacMenuBar/Shared/UsageViews.swift`（`provider.error`）、`UsageActivityState.swift`（`maxErrorLength`、`hasPartialFailure`）。
- **一律顯示最後更新時間**；過期時改為「資料已過期 · HH:mm 更新」（門檻見第 4 節）。錶面空間不足的複雜功能以灰色表示過期。
  來源：`ActivityViews.swift`（`ActivityFooter`）、`apple/MacMenuBar/Shared/UsageViews.swift`（`UpdatedText`）、`apple/iOSApp/AIUsageMonitor/Views/HomeView.swift`（`UpdatedFooter`）、`apple/WatchApp/AIUsageWatch/UsageListView.swift`。

## 7. 平台限制

| 限制 | 規則 | 來源 |
|---|---|---|
| Live Activity ContentState < 4KB | 只放畫面需要的欄位（可見額度、錯誤、更新時間、顯示模式），錯誤訊息截短；新增欄位要跑大小測試 | `UsageActivityState.swift`（`maxEncodedBytes`、`encodedSize()`）；`UsageActivityStateTests`、`FixtureTests`、`EdgeCaseTests` 檢查 < 4096 bytes（最壞情況留 512 bytes 餘裕） |
| 鎖定畫面卡片高度約 160pt | 超過會被系統截掉；標題維持單行，新增列之前先確認高度 | `apple/iOSApp/Shared/ActivityViews.swift` |
| `staleDate` 不可落在過去 | 給過去的時間，系統會直接把卡片從鎖定畫面移除；取資料過期時間與下一個重置時間中較早且尚未到的，都過去就給 `nil` | `UsageActivityState.staleDate(now:)`、`apple/iOSApp/Shared/LiveActivityController.swift` |
| Widget 擴充最低 iOS 18 | `supplementalActivityFamilies([.small])`（手錶智慧型堆疊，FR-27）需要 iOS 18；App 本身仍支援 iOS 17，不要拉高 App 的部署目標 | `apple/iOSApp/project.yml`（UsageWidget 的 `IPHONEOS_DEPLOYMENT_TARGET`）、`apple/iOSApp/UsageWidget/UsageLiveActivity.swift` |
| Mac 桌面小工具 reload 最短 25 分鐘 | 內容有變且距上次 ≥ 25 分鐘，或距上次已達 25 分鐘才 `reloadAllTimelines`；每天 ≤ 58 次。收集器每 5 分鐘寫一次，每次都 reload 會用掉約 288 次 | `apple/UsageKit/Sources/UsageKit/WidgetSupport.swift`（`WidgetReloadThrottle`）、`apple/MacMenuBar/AIUsageMenuBar/UsageStore.swift` |
| 手錶背景更新約 30 分鐘 | 每次背景更新 reload 一次複雜功能，約 48 次／天；實際時間由 watchOS 決定，過期門檻因此是 45 分鐘 | `apple/WatchApp/AIUsageWatch/AIUsageWatchApp.swift`（`backgroundInterval`） |
| WidgetKit 每日預算約 40～70 次 | **新增任何 reload 邏輯都要先估算每日次數**，連同既有的次數對照預算，寫進 PR；超過時系統會延後更新。Timeline 的時間點（重置、過期）不扣預算，優先用 timeline 而不是 reload | `WidgetSupport.swift`（`WidgetReloadThrottle` 註解、`UsageTimelineSchedule.entryDates`） |
| Mac 動畫與 3D 效果只在面板開啟時執行 | 面板關閉時不能佔 CPU／GPU；計時器允許系統合併喚醒（FR-25、NFR-8）。FR-25 尚未實作，實作時要遵守 | `docs/01-requirements.md`（FR-25、NFR-8）、`apple/MacMenuBar/AIUsageMenuBar/UsageStore.swift`（計時器容許誤差） |
| 介面語言為繁體中文（zh-Hant） | 所有使用者看得到的文字用繁體中文；開發區域設為 zh-Hant | `apple/UsageKit/Package.swift`（`defaultLocalization`）、三個 `project.yml` 的 `CFBundleDevelopmentRegion` |

## 8. UI 驗證方式

改了畫面就要實際看過，不能只靠編譯通過。

1. **一次跑完測試與建置**：`scripts/verify-all.sh`（含 Release 不含 Debug 字串的檢查）。
2. **iPhone／動態島**：在 iPhone Pro 模擬器（有動態島）安裝 Debug 版，以示範模式啟動：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
   ```
   回到主畫面，卡片會縮成動態島精簡版。情境：`normal`（Claude 最吃緊）、`codex`（Codex 最吃緊）、`stale`、`error`、`reset`、`used`。
   - `xcrun simctl io screenshot` **拍不到動態島內容**，要用模擬器控制工具的截圖。
   - 深色、淺色各拍一次：`xcrun simctl ui booted appearance dark|light`。
3. **手錶複雜功能**：錶面無法以程式設定，改用 Debug 的 `AUM_RENDER=1` 以 ImageRenderer 輸出：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER=1 xcrun simctl launch <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp
   xcrun simctl get_app_container <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp data
   ```
   `Documents/` 下有 `complication-circular.png`（深色）、`-circular-light.png`（淺色背景）、`-circular-tinted.png`（模擬單色／主題色：只用 alpha 再套主題色）。
4. **Mac**：`AUM_DEMO_PANEL=1` 把面板放進一般視窗；`AUM_RENDER_DIR=<資料夾>` 輸出桌面小工具 PNG（見 `apple/MacMenuBar/README.md`）。
5. **檢查重點**：在實際尺寸（不是放大圖）下確認八芒星八個角都看得到、雲朵中間的 `>_` 可辨認；主題色模擬中鏤空處透出背景；深色與淺色都清楚。
6. 截圖放在 `docs/screenshots/`，PR 描述附上前後對照。截圖前確認畫面上沒有中繼網址或密鑰。
7. 示範模式、截圖工具與 `AUM_*` 環境變數都要包在 `#if DEBUG` 裡。
