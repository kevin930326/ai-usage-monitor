/**
 * 第二層：多裝置 Token 合併（ADR-0011 第 2 節、FR-49）。資料在 D1（migrations/0001_tier2.sql）。
 *
 *   POST /tokens/daily               Authorization: Bearer <裝置密鑰>   上傳這台電腦的每日加總（覆蓋寫入）
 *   GET  /tokens/daily?from=YYYY-MM-DD  Authorization: Bearer <READ_TOKEN>  下載所有裝置的每日加總
 *   GET  /devices                    Authorization: Bearer <ADMIN_TOKEN>  列出裝置（不含密鑰與雜湊）
 *   POST /devices                    Authorization: Bearer <ADMIN_TOKEN>  新增裝置，回傳一次密鑰
 *   POST /devices/<id>/rotate        Authorization: Bearer <ADMIN_TOKEN>  換新密鑰（device_id 不變）
 *   POST /devices/<id>/revoke        Authorization: Bearer <ADMIN_TOKEN>  撤銷；{"delete_data": true} 一併刪除資料
 *
 * - 裝置密鑰只存 SHA-256；device_id 由密鑰決定，上傳內容中的裝置欄位一律忽略。
 * - 裝置密鑰只能寫 /tokens/daily，不能寫 /usage；READ_TOKEN／WRITE_TOKEN／ADMIN_TOKEN 都不能上傳每日加總。
 * - 只保存白名單欄位（日期、服務、模型名稱、各類 Token、任務秒數、最長任務），其他欄位丟棄。
 */

export interface D1Result<T> {
  results: T[];
}

export interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<D1Result<T>>;
  run(): Promise<unknown>;
}

/** `batch` 每個敘述的結果中用到的部分（寫入了幾列） */
export interface D1RunResult {
  meta?: { changes?: number };
}

/** Cloudflare D1 綁定中用到的部分（`batch` 在同一個交易中執行） */
export interface D1Database {
  prepare(sql: string): D1PreparedStatement;
  batch(statements: D1PreparedStatement[]): Promise<D1RunResult[]>;
}

export interface TokensEnv {
  DB?: D1Database;
  READ_TOKEN: string;
  WRITE_TOKEN: string;
  ADMIN_TOKEN?: string;
}

export const MAX_ROWS = 400;
export const MAX_TOKENS_BODY_BYTES = 256 * 1024;
/** 下載的列數上限：3 台 × 400 天 × 約 10 個模型，遠大於實際用量 */
export const MAX_DOWNLOAD_ROWS = 50_000;
export const MAX_VALUE = 1e12;
export const OLDEST_DAYS = 400;
export const TOKEN_FIELDS = [
  "input_tokens",
  "cache_write_tokens",
  "cache_read_tokens",
  "output_tokens",
  "reasoning_tokens",
  "task_seconds",
  "longest_task_seconds",
] as const;
const PROVIDERS = ["claude", "codex"];
// 與收集器的 token_stats.normalize_model 相同（ADR-0009 第 4 節）；其他名稱收集器已記為 other
const MODEL = /^(claude-|gpt-|codex-|o[0-9])[a-z0-9._-]*$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const DEVICE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// 裝置名稱會顯示在 Mac 面板：只收短的單行文字
const NAME_MAX = 32;
const KEY_PREFIX = "aumd_";

type Fields = Record<string, unknown>;
export type TokenRow = { day: string; provider: string; model: string } & Record<(typeof TOKEN_FIELDS)[number], number>;
type Result<T> = { ok: true; value: T } | { ok: false; error: string };

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function error(status: number, message: string): Response {
  return json({ error: message }, status);
}

const isObject = (v: unknown): v is Fields => typeof v === "object" && v !== null && !Array.isArray(v);

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** 先各自雜湊再逐 byte 比對，比對時間與密鑰內容無關 */
async function safeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= ha.charCodeAt(i) ^ hb.charCodeAt(i);
  return diff === 0;
}

function bearer(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  return header.startsWith("Bearer ") ? header.slice("Bearer ".length) : null;
}

async function hasToken(request: Request, expected: string | undefined): Promise<boolean> {
  const token = bearer(request);
  return !!expected && token !== null && (await safeEqual(token, expected));
}

/** UTC 日期字串（YYYY-MM-DD）往前後移幾天 */
function utcDay(now: number, offsetDays: number): string {
  return new Date(now + offsetDays * 86_400_000).toISOString().slice(0, 10);
}

/** 真的存在的日期（2 月 30 日、13 月不算） */
function isDay(v: unknown): v is string {
  if (typeof v !== "string" || !DAY.test(v)) return false;
  const date = new Date(`${v}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === v;
}

/** 日期範圍：不早於 400 天前、不晚於明天（UTC；各電腦以本機時區記日期，前後多留一天） */
export function dayInRange(day: string, now: number): boolean {
  return day >= utcDay(now, -OLDEST_DAYS) && day <= utcDay(now, 1);
}

function sanitizeRow(r: unknown, now: number): Result<TokenRow> {
  if (!isObject(r)) return { ok: false, error: "每一列必須是物件" };
  if (!isDay(r.day) || !dayInRange(r.day, now)) return { ok: false, error: `day 必須是 ${OLDEST_DAYS} 天內到明天的日期` };
  if (typeof r.provider !== "string" || !PROVIDERS.includes(r.provider)) return { ok: false, error: "provider 只能是 claude 或 codex" };
  const model = r.model;
  if (typeof model !== "string" || model.length > 64 || (model !== "other" && !MODEL.test(model))) {
    return { ok: false, error: "model 名稱不合法" };
  }
  const row: Fields = { day: r.day, provider: r.provider, model };
  for (const field of TOKEN_FIELDS) {
    const v = r[field] ?? 0;
    if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0 || v > MAX_VALUE) {
      return { ok: false, error: `${field} 必須是 0～10¹² 的整數` };
    }
    row[field] = v;
  }
  return { ok: true, value: row as TokenRow };
}

/** 驗證整批並以白名單重建；同一批不能有重複的（day、provider、model） */
export function sanitizeRows(data: unknown, now: number): Result<TokenRow[]> {
  if (!isObject(data) || !Array.isArray(data.rows)) return { ok: false, error: "內容必須是 {\"rows\": [...]}" };
  if (data.rows.length > MAX_ROWS) return { ok: false, error: `每批最多 ${MAX_ROWS} 列` };
  const rows: TokenRow[] = [];
  const seen = new Set<string>();
  for (const r of data.rows) {
    const row = sanitizeRow(r, now);
    if (!row.ok) return row;
    const key = `${row.value.day}|${row.value.provider}|${row.value.model}`;
    if (seen.has(key)) return { ok: false, error: "同一批有重複的列" };
    seen.add(key);
    rows.push(row.value);
  }
  return { ok: true, value: rows };
}

// 寫入時再確認一次密鑰仍然有效（同一個交易內）：驗證之後、寫入之前被撤銷或換新的請求不會寫回資料（C-01）
const KEY_STILL_VALID = "EXISTS (SELECT 1 FROM devices WHERE device_id = ? AND key_hash = ? AND revoked_at IS NULL)";

const TOUCH = `UPDATE devices SET last_upload_at = ? WHERE device_id = ? AND key_hash = ? AND revoked_at IS NULL`;

const UPSERT = `INSERT INTO daily_tokens (device_id, day, provider, model, ${TOKEN_FIELDS.join(", ")}, updated_at)
  SELECT ?, ?, ?, ?, ${TOKEN_FIELDS.map(() => "?").join(", ")}, ? WHERE ${KEY_STILL_VALID}
  ON CONFLICT (device_id, day, provider, model) DO UPDATE SET
  ${TOKEN_FIELDS.map((f) => `${f} = excluded.${f}`).join(", ")}, updated_at = excluded.updated_at`;

async function handleUpload(request: Request, db: D1Database, now: number): Promise<Response> {
  const token = bearer(request);
  // 裝置密鑰有固定前綴；其他密鑰（含 READ／WRITE／ADMIN）一律 401，不查資料庫
  if (token === null || !token.startsWith(KEY_PREFIX)) return error(401, "unauthorized");
  const keyHash = await sha256Hex(token);
  const device = await db
    .prepare("SELECT device_id, revoked_at FROM devices WHERE key_hash = ?")
    .bind(keyHash)
    .first<{ device_id: string; revoked_at: number | null }>();
  if (!device || device.revoked_at !== null) return error(401, "unauthorized");

  const body = await request.text();
  if (new TextEncoder().encode(body).length > MAX_TOKENS_BODY_BYTES) return error(413, "內容過大");
  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch {
    return error(400, "內容不是合法的 JSON");
  }
  const rows = sanitizeRows(data, now);
  if (!rows.ok) return error(422, rows.error);

  const seconds = Math.floor(now / 1000);
  const id = device.device_id;
  // 第一個敘述記錄上傳時間（空的一批也記錄：收集器用它取得自己的 device_id），同時判斷密鑰在交易中是否仍然有效
  const statements = [db.prepare(TOUCH).bind(seconds, id, keyHash)];
  for (const r of rows.value) {
    statements.push(db.prepare(UPSERT).bind(id, r.day, r.provider, r.model, ...TOKEN_FIELDS.map((f) => r[f]), seconds, id, keyHash));
  }
  const results = await db.batch(statements);
  if ((results[0]?.meta?.changes ?? 0) === 0) return error(401, "unauthorized");
  return json({ device_id: id, accepted: rows.value.length });
}

type DeviceRow = { device_id: string; name: string; created_at: number; revoked_at: number | null; last_upload_at: number | null };

const iso = (seconds: number | null) => (seconds === null ? null : new Date(seconds * 1000).toISOString().replace(".000Z", "Z"));

function deviceJSON(d: DeviceRow) {
  return {
    device_id: d.device_id,
    name: d.name,
    created_at: iso(d.created_at),
    revoked: d.revoked_at !== null,
    last_upload_at: iso(d.last_upload_at),
  };
}

async function handleDownload(request: Request, db: D1Database, env: TokensEnv, now: number): Promise<Response> {
  if (!(await hasToken(request, env.READ_TOKEN))) return error(401, "unauthorized");
  const from = new URL(request.url).searchParams.get("from");
  if (!isDay(from)) return error(422, "from 必須是 YYYY-MM-DD");
  const since = from < utcDay(now, -OLDEST_DAYS) ? utcDay(now, -OLDEST_DAYS) : from;
  const devices = await db.prepare("SELECT device_id, name, created_at, revoked_at, last_upload_at FROM devices ORDER BY created_at").all<DeviceRow>();
  const rows = await db
    .prepare(`SELECT device_id, day, provider, model, ${TOKEN_FIELDS.join(", ")} FROM daily_tokens WHERE day >= ? ORDER BY day LIMIT ?`)
    .bind(since, MAX_DOWNLOAD_ROWS)
    .all<Fields>();
  return json({ devices: devices.results.map(deviceJSON), rows: rows.results });
}

function newKey(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return KEY_PREFIX + btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function readJSON(request: Request): Promise<Fields | null> {
  const text = await request.text();
  if (text.length > 4096) return null;
  if (text.trim() === "") return {};
  try {
    const data = JSON.parse(text);
    return isObject(data) ? data : null;
  } catch {
    return null;
  }
}

/** 名稱只收 1～32 字的單行文字（不含控制字元）；前後空白去掉 */
export function cleanName(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const name = v.trim();
  if (name === "" || [...name].length > NAME_MAX || /[\u0000-\u001f\u007f\u2028\u2029]/.test(name)) return null;
  return name;
}

async function handleDevices(request: Request, db: D1Database, env: TokensEnv, pathname: string, now: number): Promise<Response> {
  if (!(await hasToken(request, env.ADMIN_TOKEN))) return error(401, "unauthorized");
  const seconds = Math.floor(now / 1000);
  if (pathname === "/devices") {
    if (request.method === "GET") {
      const list = await db.prepare("SELECT device_id, name, created_at, revoked_at, last_upload_at FROM devices ORDER BY created_at").all<DeviceRow>();
      return json({ devices: list.results.map(deviceJSON) });
    }
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "GET, POST" } });
    const body = await readJSON(request);
    const name = cleanName(body?.name);
    if (name === null) return error(422, `name 必須是 1～${NAME_MAX} 字的單行文字`);
    const key = newKey();
    const deviceId = crypto.randomUUID();
    await db
      .prepare("INSERT INTO devices (device_id, name, key_hash, created_at) VALUES (?, ?, ?, ?)")
      .bind(deviceId, name, await sha256Hex(key), seconds)
      .run();
    return json({ device_id: deviceId, name, key }, 201);
  }

  const match = /^\/devices\/([^/]+)\/(rotate|revoke)$/.exec(pathname);
  if (!match) return error(404, "not found");
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
  const [, deviceId, action] = match;
  if (!DEVICE_ID.test(deviceId)) return error(404, "找不到裝置");
  const device = await db.prepare("SELECT device_id, revoked_at FROM devices WHERE device_id = ?").bind(deviceId).first<DeviceRow>();
  if (!device) return error(404, "找不到裝置");

  if (action === "rotate") {
    if (device.revoked_at !== null) return error(409, "裝置已撤銷，請新增一台");
    const key = newKey();
    await db.prepare("UPDATE devices SET key_hash = ? WHERE device_id = ?").bind(await sha256Hex(key), deviceId).run();
    return json({ device_id: deviceId, key });
  }
  const body = await readJSON(request);
  if (body === null || (body.delete_data !== undefined && typeof body.delete_data !== "boolean")) {
    return error(422, "delete_data 必須是布林值");
  }
  const statements = [
    // 撤銷後雜湊換成不可能對上的值：舊密鑰無法再查到這台裝置
    db.prepare("UPDATE devices SET revoked_at = COALESCE(revoked_at, ?), key_hash = ? WHERE device_id = ?").bind(seconds, `revoked:${deviceId}`, deviceId),
  ];
  if (body.delete_data === true) statements.push(db.prepare("DELETE FROM daily_tokens WHERE device_id = ?").bind(deviceId));
  await db.batch(statements);
  return json({ device_id: deviceId, revoked: true, deleted_data: body.delete_data === true });
}

/** /tokens/daily 與 /devices；其他路徑回傳 null 交給呼叫端 */
export async function handleTier2(request: Request, env: TokensEnv, now = Date.now()): Promise<Response | null> {
  const { pathname } = new URL(request.url);
  const isTokens = pathname === "/tokens/daily";
  const isDevices = pathname === "/devices" || pathname.startsWith("/devices/");
  if (!isTokens && !isDevices) return null;
  // 第二層是選用的：沒有 D1 綁定時不影響 /usage
  if (!env.DB) return error(503, "第二層未設定（沒有 D1 綁定）");
  if (isDevices) {
    if (!env.ADMIN_TOKEN || env.ADMIN_TOKEN === env.READ_TOKEN || env.ADMIN_TOKEN === env.WRITE_TOKEN) {
      return error(503, "裝置管理未設定（ADMIN_TOKEN 未設定或與其他密鑰相同）");
    }
    return handleDevices(request, env.DB, env, pathname, now);
  }
  switch (request.method) {
    case "GET":
      return handleDownload(request, env.DB, env, now);
    case "POST":
      return handleUpload(request, env.DB, now);
    default:
      return new Response(null, { status: 405, headers: { Allow: "GET, POST" } });
  }
}
