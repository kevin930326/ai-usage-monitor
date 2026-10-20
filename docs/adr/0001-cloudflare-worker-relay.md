# ADR-0001：使用 Cloudflare Worker 作為中繼

- 狀態：已採用
- 日期：2026-10-20

## 背景

Mac 上的收集器需要把用量資料送到 iPhone。限制：不使用付費 Apple Developer 帳號、Mac 不一定與手機同網路。

## 考慮過的選項

| 選項 | 優點 | 缺點 |
|---|---|---|
| iCloud Drive 檔案 | 不用架伺服器 | iOS App 讀 iCloud 需 iCloud capability，免費帳號不支援 |
| Mac 本機 HTTP + Tailscale | 資料不經第三方 | Mac 關機就讀不到；手機需裝 VPN |
| **Cloudflare Worker + KV** | 免費、隨處可讀、Mac 關機仍有最後一筆 | 多一個部署元件，需處理驗證 |

## 決定

採用 Cloudflare Worker + KV，讀寫分別使用不同密鑰。

## 影響

- 只上傳百分比與重置時間，OAuth token 不離開 Mac。
- 需在 README 說明如何部署 Worker 與設定密鑰。
