# Windows 桌面 App

PC 上的懸浮圓環與卡片式面板（[ADR-0015](../docs/adr/0015-windows-desktop-app.md)，FR-61）。WPF／.NET 10，x64 與 ARM64。
**只讀本機檔案**：收集器寫的 `%LOCALAPPDATA%\AIUsageMonitor\usage.json`。App 不連網、不持有密鑰；唯一啟動的程式是按「立即更新」時的
`schtasks.exe /Run /TN \AIUsageMonitor\Collector`（觸發收集器，60 秒內一次、24 小時 100 次）。

目前是階段 1：懸浮圓環、系統匣圖示、面板（主圓環卡片、額度卡片）、設定。Token 統計、走勢、通知等見 ADR-0015 第 5 節的階段表。

## 資料夾結構

```
windows/
├── AIUsageMonitor.sln
├── Directory.Build.props        # 共用設定（Nullable、TreatWarningsAsErrors、不帶網路的隱含 using）
├── src/
│   ├── UsageCore/               # net10.0 純邏輯（UsageKit 的 C# 移植）：解析 usage.json、剩餘／預期進度／用得太快、
│   │                            #   文字、圓環內容、位置計算、全螢幕判斷、設定檔。Mac／Linux 上也能測試
│   └── AIUsageMonitor.Windows/  # net10.0-windows WPF
│       ├── App.xaml(.cs)        # 進入點、單一執行個體與命令列（--show-panel／--hide-panel／--quit）
│       ├── AppHost.cs           # 把下面各部分接起來：每分鐘的計時器、顯示方式、選單、開關面板
│       ├── RingWindow.cs        # 懸浮圓環（不搶焦點、拖動、點一下）
│       ├── PanelWindow.cs       # 面板視窗（Mica／壓克力或純色、動畫、點外面關閉）
│       ├── PanelContent.cs      # 面板的卡片（截圖也用這個）
│       ├── SettingsWindow.cs    # 設定
│       ├── TrayIcon.cs          # 系統匣圖示（Shell_NotifyIcon，沒有 WinForms）
│       ├── FullscreenWatcher.cs # 全螢幕偵測（事件驅動，沒有輪詢）
│       ├── UsageStore.cs        # 監看與讀取 usage.json、設定檔、紀錄檔
│       ├── SystemServices.cs    # 單一執行個體、開機自動啟動（HKCU Run）、觸發收集器（唯一啟動程式的地方）
│       ├── Drawing.cs、Theme.cs  # 圓環、服務圖示、額度條；顏色與系統外觀
│       ├── NativeMethods.cs     # Win32 P/Invoke
│       └── DebugTools.cs        # 只在 Debug：示範資料與截圖
├── tests/
│   └── UsageCore.Tests/         # xUnit：golden 比對（和 Swift 共用 ../fixtures/logic）與單元測試
└── tools/
    ├── check-no-network.py      # 靜態檢查：不連網、不碰密鑰、只有一處啟動程式、Release 不含 Debug 字串
    ├── measure-perf.ps1         # 效能量測
    └── make-ico.py              # 產生 Assets/AppIcon.ico
```

使用者執行的安裝腳本是 [`scripts/install-windows-app.ps1`](../scripts/install-windows-app.ps1)。

## 安裝（PC）

1. 先以 `-WithQuota` 安裝收集器（[docs/windows.md](../docs/windows.md)），App 才有額度資料：

   ```powershell
   cd <repo>\collector
   powershell -ExecutionPolicy Bypass -File windows\install-task.ps1 -WithQuota
   ```

2. 安裝 App（不需要系統管理員；沒有 .NET 10 SDK 時會詢問是否用 winget 安裝）：

   ```powershell
   cd <repo>
   powershell -ExecutionPolicy Bypass -File scripts\install-windows-app.ps1
   ```

   依這台電腦的架構建置，裝到 `%LOCALAPPDATA%\AIUsageMonitor\WindowsApp`、加入開機自動啟動並啟動。
   **更新**：`git pull` 後再執行一次（舊版改名 `WindowsApp.old`）。**移除**：加 `-Uninstall`（設定檔與收集器的資料保留）。

從 repo 建置的檔案沒有 Mark of the Web，不會出現 SmartScreen 的「Windows 已保護您的電腦」。

**從 Release 的 zip 安裝**（發布後；不需要 .NET）：下載符合架構的 `AIUsageMonitor-windows-<x64|arm64>-<版本>.zip`，以 `SHA256SUMS-windows`
比對（`Get-FileHash <zip> -Algorithm SHA256`），解壓到固定的位置（例如 `%LOCALAPPDATA%\AIUsageMonitor\WindowsApp`）後打開
`AIUsageMonitor.exe`。zip 是自含式（內含 .NET 執行環境）、沒有程式碼簽章，第一次打開會出現 SmartScreen，按「其他資訊」→「仍要執行」。
開機自動啟動在 App 的設定裡打開。發布流程見 [docs/release-checklist.md](../docs/release-checklist.md)。

## 使用

- **懸浮圓環**：外圈是剩餘 %、內圈是距離重置的時間；剩不到 20% 變紅、用得太快加一個點、資料過期（30 分鐘沒更新）變灰色虛線。
  拖動移位置，放開時靠近邊緣（16 DIP 內）會貼齊；每個螢幕各記一個位置。點一下開關面板，右鍵選單有「打開面板」「立即更新」「設定…」「隱藏圓環」「結束」。
  全螢幕的 App 在同一個螢幕時自動隱藏。
- **系統匣圖示**：同樣的雙圓環；按兩下開關面板，右鍵同上。
- **面板**：主圓環卡片（剩餘最少的額度）、額度卡片（5 小時與每週的條、預期進度的標記、用得太快的提示、重置倒數）、上方是更新時間與過期提示。點面板外面或按 Esc 收起。
- **設定**：顯示方式（圓環＋系統匣／只有圓環／只有系統匣）、圓環顯示的額度（自動＝剩餘最少的）、大小、透明度、全螢幕時隱藏、登入時自動啟動、外觀（跟隨系統／淺色／深色）。
  「顯示動畫」跟隨 Windows 的「設定 › 協助工具 › 視覺效果 › 動畫效果」。

寫入的檔案：`%LOCALAPPDATA%\AIUsageMonitor\windows-app.json`（設定與圓環位置）、`logs\windows-app.log`（錯誤的類型與位置，256 KB 輪替）、
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的 `AIUsageMonitor`（只在開機自動啟動打開時）。

## 開發

Mac 上只能編譯與跑純邏輯測試（`brew install dotnet`）；畫面、截圖與效能在 GitHub Actions 的 Windows runner。

```bash
dotnet test windows/tests/UsageCore.Tests                       # golden 與單元測試（Mac、Linux、Windows）
dotnet build windows/AIUsageMonitor.sln                         # Mac 上以 EnableWindowsTargeting 編譯
python3 windows/tools/check-no-network.py                       # 靜態檢查
scripts/verify-all.sh                                           # 也包含上面三項與 x64／ARM64 的 Release 建置
```

- **計算一致**：`fixtures/logic/cases.json` 的每個案例由 Swift（`apple/UsageKit/Tests/UsageKitTests/LogicGoldenTests.swift`）與 C#
  （`tests/UsageCore.Tests/LogicGoldenTests.cs`）各算一次，都要等於 `golden.json`。改了計算時兩邊一起改；新增案例後以
  `AUM_UPDATE_GOLDEN=1 swift test --filter LogicGoldenTests`（在 `apple/UsageKit`）重寫 golden，再確認 C# 也通過。
- **「現在」**：畫面上的時間一律用 `Clock.Now`（截圖時固定）。
- **Windows 上執行 Debug 版**：`AIUsageMonitor.exe --demo <normal|too_fast|critical|stale|error|single|none>` 以示範資料啟動（暫存資料夾，不碰真實資料，也不改開機自動啟動）。
- **`--isolated`**（Release 也有）：不改開機自動啟動、不觸發收集器；效能量測以它加上暫存資料夾的 `AI_USAGE_MONITOR_HOME` 啟動。
  `AI_USAGE_MONITOR_HOME` 本身只決定資料夾（和收集器相同），設了它 App 照常運作。

### 截圖

CI 的 `Windows App` job 以 Debug 版產生、上傳成 artifact `windows-screens`：

```powershell
AIUsageMonitor.exe --render build\win-screens --now 2026-10-26T09:30:00Z
```

固定時間、示範資料、2×，淺色與深色各一份：`ring-{normal,too_fast,critical,stale,empty}`（棋盤格底）、`tray-*`（64 px）、
`panel-{normal,too_fast,critical,stale,error,single,none,nodata,hint}`、`settings`。階段 1 只產生、不比對基準。

### 效能

CI 以 Release 版跑 `tools/measure-perf.ps1 -Ci`，結果在 job summary 與 artifact `windows-perf`。正式紀錄以 x64 桌機為準：

```powershell
windows\tools\measure-perf.ps1 -Exe $env:LOCALAPPDATA\AIUsageMonitor\WindowsApp\AIUsageMonitor.exe
```

| 狀態 | 門檻（桌機） | CI 警告 |
|---|---|---|
| 閒置（圓環顯示、面板關閉） | CPU ≤ 0.1% | > 0.3% |
| 面板開啟、靜止 | ≤ 2% | > 4% |
| 關閉後 1 分鐘 | ≤ 0.3% | > 0.6% |
| 開關 5 次後的記憶體 | 工作集 ≤ +5 MB | 同（失敗） |

量測時 App 以暫存資料夾當 `AI_USAGE_MONITOR_HOME`，不碰真實資料。先結束正在執行的 App（單一執行個體）。

## 實機確認

CI 看不到滑鼠、焦點與多螢幕的行為，在 x64 桌機（Windows 11）與 Parallels 的 ARM64 VM 各確認一次：

- [ ] 安裝：`scripts\install-windows-app.ps1` 成功、圓環出現在主螢幕右下角；再執行一次（更新）不留第二個 App
- [ ] 焦點：在記事本打字時點圓環、拖圓環，記事本的游標不消失（圓環不搶焦點）；Alt+Tab 看不到圓環
- [ ] 拖動與貼邊：拖到距離邊緣 16 DIP 內放開會貼齊（留 8 DIP），角落兩邊都貼；工作列那一側以工作區為準
- [ ] 點一下開關面板；點面板外面、按 Esc、再點圓環都會收起；面板貼著圓環、不超出螢幕（副螢幕較小或縮放 200% 時也是）
- [ ] 右鍵圓環（記事本在前景）：點記事本時選單收起；方向鍵能移動選單
- [ ] 在瀏覽器打字時執行 `AIUsageMonitor.exe`（第二個執行個體打開面板）：面板出現後點桌面會收起
- [ ] 全螢幕：切到全螢幕的遊戲或影片時圓環隱藏；瀏覽器按 F11 進入與離開；另一個螢幕全螢幕（含獨占全螢幕的遊戲）時這個螢幕的圓環不隱藏；設定關掉後不隱藏
- [ ] 工作列設成自動隱藏後最大化記事本：圓環**不**隱藏
- [ ] 多螢幕：拖到另一個螢幕、重新啟動後回到同一個位置；拔掉那個螢幕後圓環回到主螢幕看得見的位置
- [ ] DPI：兩個螢幕縮放不同（100%／150%）時拖過去，圓環大小（DIP）不變、不模糊
- [ ] 開機自動啟動：登出再登入後圓環出現；設定關掉後不再出現（登錄值移除）
- [ ] 單一執行個體：再執行一次 `AIUsageMonitor.exe` 不會出現第二個圓環，而是打開面板
- [ ] 外觀：跟隨系統、淺色、深色；Windows 切換深色模式時跟著變；「透明效果」關閉時面板與設定視窗是純色（設定視窗開著時切換深淺色，背景與文字一起變）
- [ ] 動畫：打開面板時圓環與條有短動畫；Windows 關閉動畫效果後直接顯示
- [ ] 系統匣：按兩下開關面板、右鍵選單；「只有系統匣」時圓環不出現；Explorer 重新啟動後圖示回來
- [ ] 不連網：防火牆封鎖 `AIUsageMonitor.exe` 對外連線後一切正常
- [ ] 效能：`measure-perf.ps1`（上面）的閒置 CPU ≤ 0.1%
