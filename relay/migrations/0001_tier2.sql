-- 第二層：多裝置 Token 合併（ADR-0011 第 2 節、FR-49）。
-- devices：每台電腦一把寫入密鑰，只存 SHA-256（hex）；device_id 由中繼產生，不信任上傳內容中的裝置欄位。
-- daily_tokens：各電腦的每日加總，以 (device_id, day, provider, model) 覆蓋寫入，重送同一列不會重複計算。
-- 只有日期、服務、模型名稱、各類 Token 數與任務秒數；沒有每小時資料、專案、路徑、session 或訊息 ID。

CREATE TABLE IF NOT EXISTS devices (
  device_id      TEXT    PRIMARY KEY,
  name           TEXT    NOT NULL,
  key_hash       TEXT    NOT NULL UNIQUE,
  created_at     INTEGER NOT NULL,
  revoked_at     INTEGER,
  last_upload_at INTEGER
);

CREATE TABLE IF NOT EXISTS daily_tokens (
  device_id            TEXT    NOT NULL REFERENCES devices (device_id),
  day                  TEXT    NOT NULL,
  provider             TEXT    NOT NULL,
  model                TEXT    NOT NULL,
  input_tokens         INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens   INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens    INTEGER NOT NULL DEFAULT 0,
  output_tokens        INTEGER NOT NULL DEFAULT 0,
  reasoning_tokens     INTEGER NOT NULL DEFAULT 0,
  task_seconds         INTEGER NOT NULL DEFAULT 0,
  longest_task_seconds INTEGER NOT NULL DEFAULT 0,
  updated_at           INTEGER NOT NULL,
  PRIMARY KEY (device_id, day, provider, model)
);

CREATE INDEX IF NOT EXISTS daily_tokens_day ON daily_tokens (day);
