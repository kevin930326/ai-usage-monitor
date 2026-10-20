# 相關專案調查

- 調查日期：2026-10-21
- 方法：以 `claude usage`、`codex usage limit`、`claude usage ios`、`live activity usage` 等約 15 組關鍵字搜尋 GitHub，依星數與相關性挑選後閱讀 README。
- 原則：只參考功能與設計概念，不複製程式碼。

## 1. 市場概況

| 平台 | 專案數量 | 觀察 |
|---|---|---|
| Mac 選單列／浮動視窗 | 最多 | 多數只支援 Claude；同時支援 Claude 與 Codex 的有數個 |
| 終端機／statusline | 多 | 以 Claude Code 使用者為主 |
| Windows 工作列 | 數個 | 部分支援多家服務 |
| 實體裝置（ESP32 小螢幕） | 數個 | 星數高，顯示「不開電腦也想看額度」的需求真實存在 |
| **iPhone** | **極少** | 只找到 Scriptable 主畫面小工具，且只支援 Claude |

## 2. 主要參考專案

| 專案 | ⭐ | 平台 | 服務 | 參考重點 |
|---|---|---|---|---|
| [Maciek-roboblog/Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | 8.7k | 終端機（Python） | Claude | 用量預測、版本化的快照格式、標示資料可信度 |
| [HermannBjorgvin/Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter) | 2.2k | ESP32 螢幕 | Claude | 證明「離開電腦也要看額度」的需求 |
| [CodeZeno/Claude-Code-Usage-Monitor](https://github.com/CodeZeno/Claude-Code-Usage-Monitor) | 629 | Windows 工作列 | 7 家 | 多服務、多帳號架構 |
| [f-is-h/Usage4Claude](https://github.com/f-is-h/Usage4Claude) | 410 | Mac 選單列 | Claude、Codex | 隱私與安全章節完整，明列所有網路請求 |
| [richhickson/claudecodeusage](https://github.com/richhickson/claudecodeusage) | 340 | Mac 選單列 | Claude | 顏色分級、各模型額度、服務中斷通知、喚醒後自動更新 |
| [zetagao/LimitHUD](https://github.com/zetagao/LimitHUD) | 83 | Mac 浮動視窗 | Claude、Codex | 最吃緊額度置頂、用完時間預測、門檻通知 |
| [intelQong/claude-usage-iOS-widget](https://github.com/intelQong/claude-usage-iOS-widget) | 0 | iPhone（Scriptable） | Claude | 唯一的 iPhone 方案，以 secret Gist 作為中繼 |

星數為調查當日數據。

## 3. 本專案的定位

| | 本專案 | 現有 iPhone 方案 | Mac／Windows 方案 |
|---|---|---|---|
| 顯示位置 | 鎖定畫面 Live Activity、動態島 | 主畫面／鎖定畫面小工具 | 電腦上 |
| 服務 | Claude + Codex | 只有 Claude | 部分兩者皆有 |
| 更新方式 | 卡片上按鈕立即更新 | 由 iOS 決定刷新時機 | 自動輪詢 |
| 實作 | 原生 SwiftUI + ActivityKit | Scriptable（JavaScript） | 各異 |

**差異點：目前沒有同時支援 Claude 與 Codex 的 iPhone Live Activity 方案。**

Mac 選單列已有多個成熟專案，因此本專案的 Mac 版（v1.2）不以功能數量取勝，重點放在：與 iPhone 共用同一個 Swift Package（NFR-7），以及面板的動態視覺（FR-25）。

## 4. 借鏡的功能

| 功能 | 來源 | 採用 | 對應需求 |
|---|---|---|---|
| 快照格式加上 `schema_version` | Maciek | ✅ v0.2 | FR-13 |
| 各模型的每週額度（Opus 等），預設隱藏 | LimitHUD、richhickson | ✅ v0.2 | FR-14 |
| 最吃緊的額度放最顯眼位置 | LimitHUD | ✅ v0.4 | FR-15 |
| 依剩餘比例顯示綠／黃／紅 | LimitHUD、richhickson | ✅ v0.4 | FR-16 |
| 切換顯示「已用」或「剩餘」 | LimitHUD、CodeZeno | ✅ v0.4 | FR-17 |
| 用完時間預測（只在早於重置時顯示） | LimitHUD、Maciek | ✅ v1.1 | FR-18 |
| 額度不足／恢復通知，含冷卻避免重複 | LimitHUD | ✅ v1.1 | FR-19 |
| README 隱私與安全章節 | Usage4Claude、intelQong | ✅ v1.0 | NFR-6 |
| Mac 選單列圖示 + 點開的詳細面板 | Usage4Claude、LimitHUD、richhickson | ✅ v1.2 | FR-21、FR-22 |
| 用量趨勢圖（sparkline） | LimitHUD | ✅ v1.2 | FR-23 |
| 卡片上的動態角色／動畫 | LimitHUD、intelQong | ✅ v1.3（改為 3D 視覺） | FR-25 |
| Claude 服務中斷通知 | richhickson | ⏸ 暫不採用 | — |
| 多帳號切換 | CodeZeno、headroom | ❌ 不採用 | 個人工具，不在範圍內 |
| 支援更多服務（Cursor、Copilot 等） | CodeZeno | ❌ 不採用 | 專注 Claude 與 Codex；provider 架構保留擴充空間 |

## 5. 中繼方案的補充

intelQong 使用 **secret GitHub Gist** 作為 Mac 與手機之間的中繼，不需額外服務帳號。缺點是取得連結的人都能讀取，也無法分開讀寫權限。本專案維持使用 Cloudflare Worker，比較見 [ADR-0001](adr/0001-cloudflare-worker-relay.md)。
