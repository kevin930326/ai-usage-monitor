---
name: ai-usage-monitor-design
description: AI Usage Monitor 的設計與識別規則：服務識別色、原創服務圖示（Claude 八芒星、Codex 六瓣雲）的精確定義、不收錄官方 logo、各平台資料過期門檻、不能更改的識別字（Bundle ID、App Group、小工具 kind、Keychain），Mac 選單列圖示（雙圓環）、卡片式面板與動畫原則，以及 UI 驗證方式。修改 apple/ 下任何畫面、顏色、圖示、Live Activity、小工具、錶面複雜功能、Info.plist／project.yml 識別字，或新增服務時先讀這份。
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
| iPhone App、Live Activity、iPhone 主畫面／鎖定畫面小工具、Mac 選單列與面板 | 30 分鐘 | `UsageSnapshot.staleAfter` |
| Apple Watch App 與錶面複雜功能 | 45 分鐘 | `UsageSnapshot.watchStaleAfter` |

手錶較長是因為背景重新整理約每 30 分鐘一次，且時間由 watchOS 決定（見 `apple/WatchApp/README.md`）。Timeline 的重新整理時間點要用和畫面相同的門檻。

## 5. 不能更改的識別字

改了會讓已安裝的 App 失去資料、Keychain 中的密鑰、使用者已加入的小工具與錶面複雜功能，或讓收集器找不到密鑰。

| 類別 | 值 |
|---|---|
| iOS App Bundle ID | `io.github.kevin930326.AIUsageMonitor` |
| Live Activity 擴充 | `io.github.kevin930326.AIUsageMonitor.UsageWidget` |
| Mac 選單列 App | `io.github.kevin930326.AIUsageMenuBar` |
| watchOS App | `io.github.kevin930326.AIUsageMonitor.watchkitapp` |
| 錶面複雜功能 | `io.github.kevin930326.AIUsageMonitor.watchkitapp.UsageComplications` |
| App Group | `group.io.github.kevin930326.AIUsageMonitor` |
| 小工具 kind | 手錶 `UsageComplication`、iPhone 主畫面／鎖定畫面 `UsageHomeWidget`（Mac 桌面小工具 `UsageDesktopWidget` 已移除，FR-24 不做） |
| iOS／watchOS Keychain | service `io.github.kevin930326.AIUsageMonitor`，account `relay-read-token` |
| Mac Keychain（收集器） | 寫入密鑰 service `AIUsageMonitor-relay-write`，account `default`；讀取密鑰 service `AIUsageMonitor-relay-read` |

另外：本機快照路徑 `~/Library/Application Support/AIUsageMonitor/usage.json` 與環境變數 `AI_USAGE_MONITOR_HOME` 由收集器與 `UsageFileLocator` 共用，兩邊要一起改；同資料夾的 `history.sqlite3`（ADR-0009）也是收集器與 App 共用。

## 6. 資訊排列

所有平台（iPhone App、Live Activity、Mac 選單列與面板、手錶 App 與複雜功能）都遵守：

- **剩餘最少的額度永遠放在最顯眼的位置**（FR-15）：所有服務的可見額度中剩餘最少的一項；畫面上**不加「剩餘最少」之類的標題**，用服務圖示＋服務名稱＋額度名稱（「Claude 每週」，`ProviderWindow.displayName`）表達；VoiceOver 仍說完整的「剩餘最少的額度：Claude 每週，剩 67%」（`leastRemainingAccessibilityLabel(mode:at:)`）；排除 `hidden` 額度與有錯誤的服務；同分時取較早重置的；已重置的額度視為剩餘 100%。一律用 `UsageSnapshot.tightestWindow(at:)`（Live Activity 用 `UsageActivityState.tightest(at:)`），不要自己挑。
  來源：`apple/UsageKit/Sources/UsageKit/UsageWindow+Reset.swift`（`tightestWindow(at:)`）、`UsageActivityState.swift`（`tightest(at:)`）。
- **服務順序固定**：Claude、Codex，其他服務依名稱排序。用 `orderedProviderKeys`，不要直接走訪 `providers` 字典（字典沒有順序）。
  來源：`apple/UsageKit/Sources/UsageKit/UsageSnapshot+Display.swift`（`knownProviderOrder`、`orderedProviderKeys`）。
- **每個額度顯示**：名稱、剩餘或已用 %、進度條、依 `resets_at` 計算的重置倒數（用 `Text(date, style: .relative)` 讓系統自己倒數，不必重新抓資料）。**例外：手錶 App 的 `List`** 裡不能放 `Text(date, style: .relative)`（重置倒數、頁尾更新時間都一樣），它每秒更新會讓 watchOS 版面不斷重算、CPU 吃滿；改用 `ResetCountdown.text(until:now:)`／`updatedText(since:now:)`，由 `TimelineView(.everyMinute)` 每分鐘更新。
  來源：`apple/UsageKit/Sources/UsageKitUI/UsageWindowRow.swift`、`UsageWindow+Reset.swift`（`UsageDisplayMode`、`displayedPct`、`ResetCountdown`）、`apple/WatchApp/AIUsageWatch/UsageListView.swift`。
- **已用／剩餘設定只在 iPhone**（FR-17，預設剩餘）：iPhone App、Live Activity（含手錶智慧型堆疊的版面）與 iPhone 主畫面／鎖定畫面小工具依設定，用 `displayedPct(mode, at:)`。Mac 選單列、面板、桌面小工具，以及手錶 App 與錶面複雜功能**固定顯示剩餘 %**（`effectiveRemainingPct`；`ComplicationView` 用預設的 `.remaining`），設定不會同步到 Mac 或手錶。
- **重置時間已過**（FR-26）：顯示「已重置」，百分比顯示剩餘 100%（已用模式為 0%）。Mac 離線時資料停在重置前，舊數字已不正確。
  來源：`UsageWindow+Reset.swift`（`isReset`、`effectiveUsedPct`）、`UsageWindowRow.swift`。
- **只有一個服務是正常狀態**：收集器只收集 Mac 上登入過的服務（`config.json` 的 `enabled_providers`），沒用的服務不會出現在 `providers`，也不是錯誤。畫面不要為缺少的服務留空位；空間大的版面（iPhone 大型小工具）改放大剩餘最少的額度、額度改單欄。`providers` 為空時顯示 `NoProvidersNotice`（`UsageSnapshot.hasNoProviders`），提示到 Mac 登入後重新執行安裝腳本。
  來源：`collector/usage_collector/providers/__init__.py`（`enabled_providers`）、`apple/UsageKit/Sources/UsageKitUI/NoProvidersNotice.swift`、`apple/iOSApp/UsageWidget/UsageHomeWidget.swift`（`LargeUsageView`）。
- **單一服務失敗只影響該服務**（FR-12）：該服務顯示錯誤訊息，其他服務照常顯示；剩餘最少的額度從正常的服務中挑。Live Activity 的錯誤訊息截短到 60 字以控制大小。
  來源：`collector/usage_collector/__main__.py`（`collect()`）、`apple/iOSApp/Shared/ActivityViews.swift`、`apple/MacMenuBar/Shared/UsageViews.swift`（`provider.error`）、`UsageActivityState.swift`（`maxErrorLength`、`hasPartialFailure`）。
- **一律顯示最後更新時間**；過期時改為「資料已過期 · HH:mm 更新」（門檻見第 4 節）。錶面空間不足的複雜功能以灰色表示過期。
  來源：`ActivityViews.swift`（`ActivityFooter`）、`apple/MacMenuBar/Shared/UsageViews.swift`（`UpdatedText`）、`apple/iOSApp/AIUsageMonitor/Views/HomeView.swift`（`UpdatedFooter`）、`apple/WatchApp/AIUsageWatch/UsageListView.swift`。
- **「更新」按鈕抓不到新資料**：卡片與小工具保留舊資料，頁尾改為「HH:mm 更新 · 更新失敗：原因」（提示色，單行截斷），下次成功就清掉。不能按了沒反應：使用者分不出是網路、密鑰還是中繼的問題。小工具的按鈕要自己呼叫 `WidgetCenter.reloadTimelines`，按鈕執行完系統不一定會重新整理時間軸。
  來源：`UsageActivityState.swift`（`refreshError`、`withRefreshError`）、`ActivityViews.swift`（`ActivityFooter`）、`LiveActivityController.refresh()`、`UsageHomeWidget.swift`（`ReloadUsageWidgetIntent`、`HomeEntry.refreshError`）。

## 7. 平台限制

| 限制 | 規則 | 來源 |
|---|---|---|
| Live Activity ContentState < 4KB | 只放畫面需要的欄位（可見額度、錯誤、更新時間、顯示模式），錯誤訊息截短；新增欄位要跑大小測試 | `UsageActivityState.swift`（`maxEncodedBytes`、`encodedSize()`）；`UsageActivityStateTests`、`FixtureTests`、`EdgeCaseTests` 檢查 < 4096 bytes（最壞情況留 512 bytes 餘裕） |
| 鎖定畫面卡片高度約 160pt | 超過會被系統截掉；標題維持單行，新增列之前先確認高度 | `apple/iOSApp/Shared/ActivityViews.swift` |
| `staleDate` 只會重繪一次、不可落在過去 | 每份內容只在 `staleDate` 重繪一次，App 也不在背景更新卡片：資料過期時間未到時一律給過期時間（過期前的重置在那次重繪一併顯示，最多晚 30 分鐘），已過期才給下一個重置時間，都過去就給 `nil`。給過去的時間，系統會直接把卡片從鎖定畫面移除 | `UsageActivityState.staleDate(now:)`、`apple/iOSApp/Shared/LiveActivityController.swift` |
| Widget 擴充最低 iOS 18 | `supplementalActivityFamilies([.small])`（手錶智慧型堆疊，FR-27）需要 iOS 18；App 本身仍支援 iOS 17，不要拉高 App 的部署目標 | `apple/iOSApp/project.yml`（UsageWidget 的 `IPHONEOS_DEPLOYMENT_TARGET`）、`apple/iOSApp/UsageWidget/UsageLiveActivity.swift` |
| iPhone 主畫面小工具 reload 25 分鐘 | 小工具自己抓中繼，每 25 分鐘（資料過期時 60 分鐘）；App 背景取得新資料時另外 reload（約 5 次／天），前景與按鈕 Intent 不扣次數。一般約 51 次／天、最多約 63 次 | `apple/iOSApp/UsageWidget/UsageHomeWidget.swift`（`refreshInterval`）、`apple/iOSApp/Shared/SharedStore.swift`（`publish`）、`apple/iOSApp/README.md`「重新整理次數」 |
| 手錶背景更新約 30 分鐘 | 每次背景更新 reload 一次複雜功能，約 48 次／天；實際時間由 watchOS 決定，過期門檻因此是 45 分鐘 | `apple/WatchApp/AIUsageWatch/AIUsageWatchApp.swift`（`backgroundInterval`） |
| WidgetKit 每日預算約 40～70 次 | **新增任何 reload 邏輯都要先估算每日次數**，連同既有的次數對照預算，寫進 PR；超過時系統會延後更新。Timeline 的時間點（重置、過期）不扣預算，優先用 timeline 而不是 reload | `WidgetSupport.swift`（`UsageTimelineSchedule.entryDates`）、`UsageHomeWidget.swift`（`refreshInterval` 註解） |
| Mac 動畫只在面板或統計視窗開啟時執行 | 面板關閉時不能佔 CPU／GPU；選單列圖示不得有持續動畫；計時器允許系統合併喚醒；規則與量測方法見第 9 節（FR-25、NFR-8、NFR-10） | `docs/adr/0010-mac-animation-principles.md`、`apple/MacMenuBar/AIUsageMenuBar/UsageStore.swift`（計時器容許誤差） |
| 介面語言為繁體中文（zh-Hant） | 所有使用者看得到的文字用繁體中文；開發區域設為 zh-Hant | `apple/UsageKit/Package.swift`（`defaultLocalization`）、三個 `project.yml` 的 `CFBundleDevelopmentRegion` |

## 8. UI 驗證方式

改了畫面就要實際看過，不能只靠編譯通過。

1. **一次跑完測試與建置**：`scripts/verify-all.sh`（含 Release 不含 Debug 字串的檢查）。
2. **iPhone／動態島**：在 iPhone Pro 模擬器（有動態島）安裝 Debug 版，以示範模式啟動：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal xcrun simctl launch booted io.github.kevin930326.AIUsageMonitor
   ```
   回到主畫面，卡片會縮成動態島精簡版。情境：`normal`（Claude 剩最少）、`codex`（Codex 剩最少）、`stale`、`error`、`reset`、`used`，以及只有一個服務的 `claude-only`、`codex-only` 與沒有服務的 `none`（見第 6 節「只有一個服務」）。
   - `xcrun simctl io screenshot` **拍不到動態島內容**，要用模擬器控制工具的截圖。
   - 深色、淺色各拍一次：`xcrun simctl ui booted appearance dark|light`。
   - **主畫面小工具**：示範情境會經由 App Group 傳給小工具。回到主畫面長按「AI 用量」圖示選尺寸（或編輯 →「加入小工具」），用 `xcrun simctl io booted screenshot` 截圖（主畫面拍得到）；長按小工具可直接換尺寸。
3. **手錶複雜功能**：錶面無法以程式設定，改用 Debug 的 `AUM_RENDER=1` 以 ImageRenderer 輸出：
   ```bash
   SIMCTL_CHILD_AUM_DEMO=normal SIMCTL_CHILD_AUM_RENDER=1 xcrun simctl launch <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp
   xcrun simctl get_app_container <手錶 UDID> io.github.kevin930326.AIUsageMonitor.watchkitapp data
   ```
   `Documents/` 下有 `complication-circular.png`（深色）、`-circular-light.png`（淺色背景）、`-circular-tinted.png`（模擬單色／主題色：只用 alpha 再套主題色）。
4. **Mac**：`AUM_DEMO_PANEL=1` 把面板放進一般視窗；`AUM_RENDER_DIR=<資料夾>` 輸出 PNG（見 `apple/MacMenuBar/README.md`）。面板、選單列圖示與動畫的截圖一律用 `ImageRenderer`（螢幕關閉也能產生），動畫輸出成 PNG 序列再組成 GIF，淺色、深色各一份。
5. **檢查重點**：在實際尺寸（不是放大圖）下確認八芒星八個角都看得到、雲朵中間的 `>_` 可辨認；主題色模擬中鏤空處透出背景；深色與淺色都清楚。
6. 截圖放在 `docs/screenshots/`，PR 描述附上前後對照。截圖前確認畫面上沒有中繼網址或密鑰。
7. 示範模式、截圖工具與 `AUM_*` 環境變數都要包在 `#if DEBUG` 裡。

## 9. Mac 選單列圖示與面板（ADR-0008、ADR-0010）

### 選單列圖示

- 預設**雙圓環**：外圈＝剩餘 %（顏色同進度條，第 1 節），內圈＝距離重置的剩餘時間占額度長度的比例（中性 `secondary`；額度長度不明時不畫）。另有橫條、只有 %、圓環＋% 三種樣式，由設定選擇；顯示的額度預設「自動（剩最少的）」＝`tightestWindow(at:)`。
- 四種狀態**不能只靠顏色區分**：正常；用得太快＝右上角提示色小點；剩 < 20%＝外圈轉紅；資料過期＝整個轉灰且外圈改為虛線（橫條為虛線外框；灰色優先）。「只有 %」樣式以符號區分：`↑` 太快、`!` 剩 < 20%、`–` 過期（只顯示優先的一個）。`accessibilityLabel` 用完整句子（自動時「剩餘最少的額度：Claude 5 小時，剩 27%，用得較快」；指定額度時不加前綴）。
- 以非範本點陣圖繪製（選單列會把 SF Symbol 與文字轉成單色）；每分鐘最多重繪一次，只在內容改變時換圖。
- **不得有持續或循環的動畫**；數值改變時最多 0.3 秒的轉場，「減少動態效果」時直接換圖。

### 預期進度與用量節奏

- 額度長度由 `id` 推得：`five_hour` 5 小時、`weekly`／`weekly_*` 7 天、`<n>h`、`<n>m`；其他為不明，不畫預期標記、不判斷節奏。一律用 UsageKit 的共用函式，不要在畫面裡自己算。
- 預期剩餘 = `100 × (1 − 經過比例)`，在額度卡片的進度條上以標記表示；標記滑鼠移上去顯示「照時間比例，現在應剩 N%」，VoiceOver 讀同一句（`expectedRemainingDescription(at:)`）。用得太快 = 已用 % 比預期多 ≥ 10 個百分點且經過 ≥ 10%，資料過期或已重置時不判斷。
- 「約 N 分鐘後用完」只在早於重置時間時顯示（FR-18）。文字用提示色（第 1 節），不用紅色。

### 面板

- 單一長版、**卡片式**：寬 360pt；卡片圓角 12pt、半透明填色（primary 4.5%）加細邊框，不疊材質（面板視窗本身已是系統材質；`ImageRenderer` 畫不出材質）；深淺色跟隨系統。
- 按鈕、開關等控制項自己畫（`ButtonStyle`／`ToggleStyle`），不用 AppKit 實作的控制項，`ImageRenderer` 才能截圖。
- 預設順序（ADR-0008 第 2 節）：主圓環 → 建議接下來用 → 額度 → 接下來的重置 → 本週額度走勢 → 額度消耗 →（之後的統計、服務狀態）。「建議接下來用」是一行提示（沒有收合箭頭），兩個服務都充足或其中一個也快用完時不顯示。頁首（標題、更新時間、更新、設定、結束）與頁尾不能關閉或移動。
- 區塊以穩定的字串 `id` 識別，順序與開關存在 `UserDefaults`；新區塊依預設順序插入、預設開啟；不認得的 id 保留但不顯示。
- 卡片可以收合，收合時不建立內容視圖（不計算、不播動畫）。
- **保留現有資訊**：剩餘最少的額度、所有可見額度、方案、重置倒數或「已重置」、服務錯誤、`NoProvidersNotice`、更新時間與「資料已過期」、讀檔錯誤與路徑。
- 歷史類卡片（走勢、額度消耗）只在面板看得見時讀 `history.sqlite3`；少於 2 筆時顯示骨架畫面與「正在收集，幾小時後開始會有資料」。沒有紀錄的時段（Mac 睡眠或關機）一律畫**斜線**，不畫成 0；額度消耗把空檔前後的差平均分到空檔的每一小時，色塊上加斜線表示「估計」，空檔中有重置時不分配。
- 圖表用 `Canvas` 畫（不用 Swift Charts），寬度以卡片內容寬 300pt（面板 360 − 兩側 16 − 卡片 14）為上限；超過會把整個面板撐寬、左邊被裁掉。
- 統計類卡片標示範圍：Token 統計＝「這台 Mac」（滑鼠移上去說明不含網頁、手機 App、其他電腦與雲端 session）；額度相關＝「整個帳號」（ADR-0011 第 4 節）。

### 動畫原則（ADR-0010）

1. 只在面板或視窗開啟時執行；關閉後停止所有動畫與為面板而設的 `TimelineView`／計時器（唯一例外：`UsageStore` 每 60 秒的計時器，負責選單列圖示，只更新資料、不啟動動畫）。選單列面板關閉時視圖仍在，以視窗的 occlusion／key 狀態判斷；看不見時把 `Text(date, style: .relative)` 換成固定文字（它在收起的視窗裡仍會定時重算）。
2. `accessibilityReduceMotion` 時改為直接顯示（只允許 ≤ 0.15 秒淡入淡出）。
3. 一次性、有終點：單次 ≤ 1.2 秒（多數 0.2～0.6 秒），重複類最多 3 次、總長 ≤ 4 秒。
4. 由資料改變或使用者操作觸發，不為動畫輪詢。
5. 以 SwiftUI 內建動畫為主（`withAnimation`、`.contentTransition(.numericText())`、`PhaseAnimator`／`KeyframeAnimator`），不用 Metal／SceneKit。
6. **每個動畫都量測效能**：`scripts/measure-panel-perf.sh`（`ps -o %cpu=,rss=`）記錄面板開啟靜止（≤ 2%）、播放中（記錄最大值）、關閉後 1 分鐘（≤ 0.3%）、第二次開關後記憶體不累積（≤ +5 MB），結果寫進 PR。
7. 每個動畫寫成 0…1 的進度值，執行時由 `withAnimation` 驅動，截圖工具以相同曲線逐格指定，輸出 PNG 序列與 GIF。
8. 第二階段的動畫（v1.6）：走勢曲線由左往右描繪 0.6 秒、最後的圓點輕彈；切換額度時新舊曲線交叉淡入 0.3 秒並重新描繪；「建議接下來用」從上方滑入 0.3 秒；時間軸圓點依序滑到位置 0.5 秒，額度重置時該圓點在「現在」放大淡出 0.5 秒；骨架掃光每次 1.2 秒、三次後停止，且只在有骨架時播放。
