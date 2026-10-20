# AI Usage Monitor

在 iPhone 鎖定畫面用 Live Activity 隨時查看 **Claude** 與 **Codex** 的剩餘使用額度（5 小時／每週），並可一鍵更新。

> 🚧 開發中，進度見 [CHANGELOG](CHANGELOG.md)。

## 系統概觀

```
Mac 收集器 (Python, launchd) ──POST──▶ Cloudflare Worker (KV) ◀──GET── iOS App (Live Activity)
                                                                      ▲
                                                    iOS 捷徑自動化：定時重開 Live Activity
```

- **token 永遠留在 Mac**，上傳的只有用量百分比與重置時間。
- 不需付費 Apple Developer 帳號：用「捷徑定時重開 + 按鈕手動更新」繞過 Live Activity 的 8 小時上限。

## 文件

| 文件 | 內容 |
|---|---|
| [需求規格](docs/01-requirements.md) | 功能需求、非功能需求、範圍 |
| [系統架構](docs/02-architecture.md) | 元件、資料格式、失敗處理 |
| [開發流程](docs/03-development-workflow.md) | 分支、commit、PR 規範 |
| [相關專案調查](docs/04-related-work.md) | 既有開源方案比較與本專案定位 |
| [架構決策紀錄 (ADR)](docs/adr/) | 重要技術選擇的理由 |

## 專案結構

```
collector/   Mac 端用量收集器 (Python)
relay/       Cloudflare Worker 中繼 API
ios/         iOS App + Live Activity Widget
docs/        需求、架構、ADR
```

## 免責聲明

本專案為個人學習作品，與 Anthropic、OpenAI 無關。用量資料取自 Claude Code 與 Codex CLI 使用的**非公開介面**，可能隨時變更或失效。
