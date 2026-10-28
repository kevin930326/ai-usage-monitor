/**
 * 跨裝置的 AI 狀態（ADR-0019 第 2 節）。資料在 D1（migrations/0002_agent_state.sql），和第二層共用 devices 表。
 *
 *   POST /agents/state   Authorization: Bearer <裝置密鑰>  {"ais":[{"ai","state","sessions","since"}]}  整台覆蓋
 *   GET  /agents/state   Authorization: Bearer <READ_TOKEN>  {"now","devices":[{"device_id","name","ais","updated_at"}]}
 *
 * - `AGENT_SYNC` 不是 `on` 時兩個端點都回 404（舊收集器與沒打開的中繼表現相同）；沒有 D1 綁定時回 503（同第二層）。
 * - 只存白名單欄位：AI（claude、codex）、六種狀態、工作階段數 0～32、進入狀態的時間。沒有資料夾名稱或任何內容。
 * - `updated_at` 由中繼寫（毫秒），`since` 夾在 `[updated_at − 24 小時, updated_at]`：各電腦的時鐘不必準。
 * - 下載不含撤銷的裝置，也不含 30 分鐘內沒有更新的裝置（那台關機或斷線；用戶端還會以 `now − updated_at` 再判斷一次）。
 */

import { bearer, type D1Database, error, hasToken, isObject, json, KEY_PREFIX, sha256Hex, type TokensEnv } from "./tokens.ts";

export const AGENT_PATH = "/agents/state";
export const MAX_AGENT_BODY_BYTES = 1024;
/** 這麼久沒更新的裝置不回傳（和 App 的顯示門檻相同） */
export const AGENT_MAX_AGE_MS = 30 * 60_000;
const SINCE_WINDOW_MS = 24 * 3_600_000;
const AIS = ["claude", "codex"];
const STATES = ["needsYou", "error", "working", "done", "waiting", "idle"];
const MAX_SESSIONS = 32;

export type AgentRow = { ai: string; state: string; sessions: number; since: number };
type Result<T> = { ok: true; value: T } | { ok: false; error: string };

/** 驗證整台的內容並以白名單重建；同一個 AI 不能出現兩次 */
export function sanitizeAgents(data: unknown, now: number): Result<AgentRow[]> {
  if (!isObject(data) || !Array.isArray(data.ais)) return { ok: false, error: "內容必須是 {\"ais\": [...]}" };
  if (data.ais.length > AIS.length) return { ok: false, error: `最多 ${AIS.length} 列` };
  const rows: AgentRow[] = [];
  for (const r of data.ais) {
    if (!isObject(r)) return { ok: false, error: "每一列必須是物件" };
    if (typeof r.ai !== "string" || !AIS.includes(r.ai)) return { ok: false, error: "ai 只能是 claude 或 codex" };
    if (rows.some((row) => row.ai === r.ai)) return { ok: false, error: "同一個 AI 出現兩次" };
    if (typeof r.state !== "string" || !STATES.includes(r.state)) return { ok: false, error: "state 不合法" };
    if (typeof r.sessions !== "number" || !Number.isInteger(r.sessions) || r.sessions < 0 || r.sessions > MAX_SESSIONS) {
      return { ok: false, error: `sessions 必須是 0～${MAX_SESSIONS} 的整數` };
    }
    if (typeof r.since !== "number" || !Number.isSafeInteger(r.since) || r.since < 0) return { ok: false, error: "since 必須是非負整數" };
    rows.push({ ai: r.ai, state: r.state, sessions: r.sessions, since: Math.min(now, Math.max(now - SINCE_WINDOW_MS, r.since)) });
  }
  return { ok: true, value: rows };
}

// 同 tokens.ts 的上傳：寫入時在同一個交易內再確認一次密鑰仍然有效
const KEY_STILL_VALID = "EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND key_hash = ? AND revoked_at IS NULL)";
const CLEAR = `DELETE FROM agent_state WHERE device_id = ? AND ${KEY_STILL_VALID}`;
const INSERT = `INSERT INTO agent_state (device_id, ai, state, sessions, since, updated_at)
  SELECT ?, ?, ?, ?, ?, ? WHERE ${KEY_STILL_VALID}`;
// 全部閒置時也留一列標記（ai = ''）：其他電腦才知道這台還在、只是沒事做，而不是 30 分鐘沒消息
const MARK = `INSERT INTO agent_state (device_id, ai, state, sessions, since, updated_at)
  SELECT ?, '', 'idle', 0, ?, ? WHERE ${KEY_STILL_VALID}`;
const TOUCH = "UPDATE devices SET last_upload_at = last_upload_at WHERE device_id = ? AND key_hash = ? AND revoked_at IS NULL";

async function handleUpload(request: Request, db: D1Database, now: number): Promise<Response> {
  const token = bearer(request);
  if (token === null || !token.startsWith(KEY_PREFIX)) return error(401, "unauthorized");
  const keyHash = await sha256Hex(token);
  const device = await db
    .prepare("SELECT device_id, revoked_at FROM devices WHERE key_hash = ?")
    .bind(keyHash)
    .first<{ device_id: string; revoked_at: number | null }>();
  if (!device || device.revoked_at !== null) return error(401, "unauthorized");

  const body = await request.text();
  if (new TextEncoder().encode(body).length > MAX_AGENT_BODY_BYTES) return error(413, "內容過大");
  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch {
    return error(400, "內容不是合法的 JSON");
  }
  const rows = sanitizeAgents(data, now);
  if (!rows.ok) return error(422, rows.error);

  const id = device.device_id;
  // 第一個敘述只用來判斷密鑰在交易中是否仍然有效（不改任何欄位）
  const statements = [db.prepare(TOUCH).bind(id, keyHash), db.prepare(CLEAR).bind(id, id, keyHash)];
  for (const r of rows.value) statements.push(db.prepare(INSERT).bind(id, r.ai, r.state, r.sessions, r.since, now, id, keyHash));
  if (rows.value.length === 0) statements.push(db.prepare(MARK).bind(id, now, now, id, keyHash));
  const results = await db.batch(statements);
  if ((results[0]?.meta?.changes ?? 0) === 0) return error(401, "unauthorized");
  return json({ device_id: id, accepted: rows.value.length });
}

type StateRow = { device_id: string; name: string; ai: string; state: string; sessions: number; since: number; updated_at: number };

async function handleDownload(request: Request, db: D1Database, env: TokensEnv, now: number): Promise<Response> {
  if (!(await hasToken(request, env.READ_TOKEN))) return error(401, "unauthorized");
  const list = await db
    .prepare(
      `SELECT a.device_id, d.name, a.ai, a.state, a.sessions, a.since, a.updated_at FROM agent_state a
         JOIN devices d ON d.device_id = a.device_id
         WHERE d.revoked_at IS NULL AND a.updated_at >= ?
         ORDER BY d.created_at, a.device_id, a.ai`,
    )
    .bind(now - AGENT_MAX_AGE_MS)
    .all<StateRow>();
  const devices: { device_id: string; name: string; ais: AgentRow[]; updated_at: number }[] = [];
  for (const r of list.results) {
    let device = devices.at(-1);
    if (device?.device_id !== r.device_id) {
      device = { device_id: r.device_id, name: r.name, ais: [], updated_at: r.updated_at };
      devices.push(device);
    }
    device.updated_at = Math.max(device.updated_at, r.updated_at);
    if (r.ai !== "") device.ais.push({ ai: r.ai, state: r.state, sessions: r.sessions, since: r.since });
  }
  return json({ now, devices });
}

/** /agents/state；其他路徑回傳 null 交給呼叫端 */
export async function handleAgents(request: Request, env: TokensEnv, now = Date.now()): Promise<Response | null> {
  if (new URL(request.url).pathname !== AGENT_PATH) return null;
  if (env.AGENT_SYNC !== "on") return error(404, "not found");
  if (!env.DB) return error(503, "第二層未設定（沒有 D1 綁定）");
  switch (request.method) {
    case "GET":
      return handleDownload(request, env.DB, env, now);
    case "POST":
      return handleUpload(request, env.DB, now);
    default:
      return new Response(null, { status: 405, headers: { Allow: "GET, POST" } });
  }
}
