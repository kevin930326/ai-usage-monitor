---
name: codex-review
description: 開 PR 前以 Codex 唯讀審查目前分支（scripts/codex-review.sh），並寫 triage：每項接受（附 commit）、拒絕（附理由與證據）或需要使用者決定（附選項與建議），只修接受的項目、每項一個 commit。準備開 PR、使用者要求審查，或 Codex 額度不足需要改用其他審查者時先讀這份。
---

# Codex 審查與 triage

## 什麼時候跑

- **每個 PR 開出（或 push 最後一版）之前**：功能做完、`scripts/verify-all.sh` 通過之後執行一次。
- 審查後又改了不小的東西（新功能、重寫、修正牽動多個檔案）：再跑一次，報告會覆蓋同一個檔案，舊的 triage 改名保留（`…-triage-1.md`）。
- 只改文件或錯字的 PR 也要跑（便宜，且能抓到與 ADR 不一致的描述）。

## 怎麼跑

```bash
scripts/codex-review.sh          # 審 git diff origin/main...HEAD（預設 --diff）
scripts/codex-review.sh --full   # 審整個 repo
```

- 在要審的 worktree 裡執行。報告：`~/Documents/ai-usage-monitor-work/reviews/<分支，斜線換成 ->-codex.md`（第一行是腳本寫的模型與範圍，第二段起是 Codex 的報告），完整輸出在同名 `.log`。
- 模型固定 `gpt-6.1-sol`、reasoning effort `medium`、`--sandbox read-only`。**不要改用其他模型**：腳本在模型無法使用、額度不足或失敗時以非 0 結束（3 找不到 codex、4 執行失敗），並且不覆蓋上一份報告。
- 跑之前看 `~/Library/Application Support/AIUsageMonitor/usage.json` 的 Codex 5 小時額度：剩不到 20%，或腳本失敗、額度不足時，**不要等額度重置**，改派一個 subagent（Fable）做同樣的審查：給它腳本裡同一段指示（`PROMPT=` 那段）與同樣的範圍與輸出格式，報告寫到同一個路徑，第一行註明「改用 Fable 審查（原因：…）」。triage 也註明。
- Codex 跑 5～15 分鐘，放在背景執行，期間可以做別的事（但不要再改這個分支）。

## 怎麼寫 triage

檔案：報告旁邊的 `<分支->-codex-triage.md`。開頭寫審查方式（Codex 或「改用 Fable 審查」、範圍、報告路徑），然後一張表，每一項一列：

| 項目 | 嚴重度 | 判定 | 處理 |
|---|---|---|---|
| C-01 標題 | 中 | **接受** | `abc1234`：做了什麼；怎麼驗證（測試名稱或手動步驟） |
| C-02 標題 | 低 | **拒絕** | 理由＋證據（檔案:行號、測試、ADR 條文、實測結果）。不能只寫「不需要」 |
| C-03 標題 | 中 | **需要你決定** | 選項 A／B（各自的影響）；建議與理由；目前先採用哪個（保守的那個） |

判定原則：

- **先自己驗證**每一項：讀程式、跑測試或寫一個重現。審查者常誤讀；誤報就拒絕並附證據。
- **接受**：確實是問題、修法不需要改 ADR 或需求。
- **拒絕**：誤報、已有處理、或與 ADR／使用者的決定牴觸（引用條文）。
- **需要你決定**：修法會改變 ADR、需求、使用者看得到的行為，或有取捨（效能 vs. 正確、隱私 vs. 功能）。先採用最保守的做法，不要停下來等。
- 「高」嚴重度的項目沒有處理（接受並修好，或有證據地拒絕）之前不合併。

## 修正

- **只修接受的項目，每項一個 commit**（`fix(<scope>): <摘要> (C-0N)`），commit 內含對應的測試；triage 的「處理」欄填 commit SHA。
- 不要順手修報告以外的東西；另外發現的問題另開 commit 並在 triage 最後列出「審查外的修正」。
- 修完重跑 `scripts/verify-all.sh`，PR 內文附 triage 的摘要（幾項接受／拒絕／需要決定）。
