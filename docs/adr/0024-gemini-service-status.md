# ADR-0024：Gemini 的服務狀態讀 Google Cloud 狀態頁

- 狀態：**已採用**
- 日期：2026-11-25
- 相關需求：FR-45（服務狀態）
- 相關：[ADR-0018](0018-quota-forecast-and-service-incidents.md) 第 4 節（Claude、Codex 的事故）、[ADR-0015](0015-windows-desktop-app.md) 第 2 節（Windows 唯一的網址例外）、[ADR-0022](0022-gemini-usage-via-antigravity.md)（Gemini 額度）

## 背景

Mac 面板的服務狀態只有 Claude 與 Codex。ADR-0022 加入 Gemini（Antigravity）時，Gemini 沒有狀態來源，除了額度用完以外不列在服務狀態裡，所以 Gemini 出問題時看不出是服務異常還是自己的問題。

## 調查（2026-11-25）

- Antigravity 沒有官方狀態頁：第三方監測網站（StatusGator、IsDown）都這麼寫，開發者論壇也有人要求官方提供。
- Google AI Studio 的狀態頁（`aistudio.google.com/status`）由 JavaScript 產生，HTML 裡沒有可讀的資料端點。它也是 Gemini API 的狀態，和 Antigravity 不同。
- Google Cloud 的公開狀態頁有 JSON：`https://status.cloud.google.com/incidents.json`，內容是最近幾個月的所有事故，實測約 300 KB。
  - 每筆有 `id`、`begin`、`end`（進行中為空）、`external_desc`、`severity`（low／medium／high）、`status_impact`（`SERVICE_INFORMATION`／`SERVICE_DISRUPTION`／`SERVICE_OUTAGE`）、`affected_products`（`title`、`id`）與 `uri`（`incidents/<id>`）。
  - `products.json` 裡有兩個相關產品：「Google Antigravity for enterprises」（`hZpxrZf6wIdajCN6y30V`）與「Gemini Code Assist」（`deUeOEPYanfJ9w8cpyBJ`）。個人版的 Antigravity 和 Gemini Code Assist 走同一個後端（Cloud Code Assist API）。
  - 產品會改名，例如 Vertex AI 改成 Agent Platform，`current_title` 跟著變，ID 不變。

## 決定

1. **Gemini 的服務狀態來源是 Google Cloud 狀態頁**：`PAGES["gemini"] = https://status.cloud.google.com`，只讀 `incidents.json`，回應上限 4 MB，逾時與間隔同其他服務。請求不帶密鑰或 cookie，也不跟隨重新導向。
2. **只算相關產品**：
   - 比對產品 ID，兩個 ID 是上面那兩個產品；
   - 產品名稱含「Antigravity」的也算（日後新增的個人版之類）；
   - Vertex 的 Gemini API 不算：那是企業用的另一套服務，算進去角色會常常無故生病。
3. **進行中**的定義是 `end` 為空，且 `begin` 是有時區的時間。
4. **影響程度**：
   - `status_impact` 對應影響程度：`SERVICE_INFORMATION` 是 none，`SERVICE_DISRUPTION` 是 minor，`SERVICE_OUTAGE` 是 major；不認得的值當 minor。
   - `severity` 為 high 時，none 以外的影響程度升一級。
   - 整體狀態（`indicator`）取最嚴重的事故。
5. **與 Statuspage 相同的欄位**：輸出的形狀和 Claude、Codex 一樣（`indicator`、`components`、`incidents`、`page`、`error`、`incidents_checked`），App、usage.json 的 `incidents` 與中繼都不必分辨來源。
   - 元件是受影響的相關產品，名稱用收集器自己的固定名稱，不用狀態頁的字串，並一律標為相關。所以 Mac 面板會寫「可能影響 Antigravity」。
   - 事故名稱取 `external_desc`，最長 120 字；更新內文不保存。
6. **事故頁連結的白名單加上 `https://status.cloud.google.com/incidents/<ID>`**，規則與另外兩個網域相同。以下幾處一起更新，`fixtures/incident-links.json` 加了這個網域的例子：
   - Swift `ServiceIncident.allowedHosts`；
   - C# `IncidentLink`；
   - `windows/tools/check-no-network.py`；
   - 中繼的 `INCIDENT_URL`。

   這是 ADR-0015 第 2 節網址例外的擴充：仍然只在使用者點擊時，交給預設瀏覽器打開。

## 影響

- Mac 面板的服務狀態有 Gemini 一列。正常時那一行寫「服務正常 · Claude、Codex、Gemini」，「狀態頁」按鈕打開 Google Cloud 狀態頁。
- 收集器每輪多一個 HTTP 請求，約 300 KB，至少間隔 4 分鐘，比 Statuspage 的 summary.json 大。
- 有 Google Cloud 事故而 Antigravity 個人版不受影響時，角色可能會生病；反過來，只影響個人版、Google 沒公告的問題讀不到。這是在沒有官方狀態頁時能拿到的最好來源。
- 中繼要重新部署，才會保留 Gemini 事故的連結。部署前事故照常顯示，只是不能點。
