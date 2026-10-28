-- 跨裝置的 AI 狀態（ADR-0019 第 2 節）。每台電腦每個 AI 一列，上傳時整台覆蓋；沒有歷史。
-- 只有 AI、狀態、工作階段數與時間；沒有資料夾名稱、工作階段 ID、對話或指令內容。
-- 撤銷裝置時一併刪除它的列（tokens.ts 的 revoke）。

CREATE TABLE IF NOT EXISTS agent_state (
  device_id  TEXT    NOT NULL REFERENCES devices (device_id),
  ai         TEXT    NOT NULL,
  state      TEXT    NOT NULL,
  sessions   INTEGER NOT NULL,
  since      INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, ai)
);
