/**
 * 中繼 API：Mac 收集器上傳最新一筆用量，iPhone 讀取（FR-6、ADR-0001）。
 *
 *   POST /usage       Authorization: Bearer <WRITE_TOKEN>
 *   GET  /usage       Authorization: Bearer <READ_TOKEN>
 *   POST /pair        Authorization: Bearer <WRITE_TOKEN>   產生一次性短碼（ADR-0012）
 *   POST /pair/claim  不需要密鑰，{"code": "..."}            以短碼兌換讀取密鑰
 *
 * 第二層（多裝置 Token 合併，選用）的 /tokens/daily 與 /devices 在 tokens.ts。
 */

import { handleTier2, OLDEST_DAYS, pruneOldDays, type TokensEnv } from "./tokens.ts";

export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface Env extends TokensEnv {
  USAGE_KV: KV;
  READ_TOKEN: string;
  WRITE_TOKEN: string;
}

export const SUPPORTED_SCHEMA_VERSIONS = [1];
// 要裝得下 LIMITS 允許的最大快照（8 個服務 × 16 個額度約 18 KB），實際快照約 1～2 KB
export const MAX_BODY_BYTES = 64 * 1024;
const LATEST_KEY = "latest";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

function error(status: number, message: string): Response {
  return json({ error: message }, status);
}

/** 先各自雜湊再逐 byte 比對，比對時間與密鑰內容無關，避免時序攻擊。 */
async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}

async function authorized(request: Request, expected: string): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Bearer ")) return false;
  return safeEqual(header.slice("Bearer ".length), expected);
}

// 上限遠大於實際用量（目前 2 個服務、每個最多約 6 個額度），只為擋下明顯錯誤的內容
export const LIMITS = {
  providers: 8, windows: 16, plan: 64, error: 500, id: 64, label: 64, maxPct: 1000,
  // 重置次數卷：張數上限與明細（依到期時間分組）筆數上限，和收集器的 MAX_RESET_CREDITS／MAX_RESET_CREDIT_DETAILS 相同
  resetCredits: 1000, resetCreditDetails: 16,
  // 額度預測的倍數、服務事故（ADR-0018）：和收集器的 SNAPSHOT_INCIDENTS／MAX_TEXT 相同
  faster: 1000, incidents: 3, incidentName: 120,
};
const IMPACTS = ["none", "minor", "major", "critical", "maintenance"];
// 事故連結只收兩個官方狀態頁的事故頁
const INCIDENT_URL = /^https:\/\/status\.(claude|openai)\.com\/incidents\/[A-Za-z0-9_-]{1,64}$/;
const PROVIDER_KEY = /^[a-z0-9_-]{1,32}$/;
// 收集器輸出整秒的 ISO 8601；不收小數秒，iOS 17／macOS 14 的 ISO8601DateFormatter 解不出來
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/;

type Fields = Record<string, unknown>;
type Result<T> = { ok: true; value: T } | { ok: false; error: string };

const fail = (error: string): { ok: false; error: string } => ({ ok: false, error });
const isObject = (v: unknown): v is Fields => typeof v === "object" && v !== null && !Array.isArray(v);
// Date.parse 會把 2 月 30 日自動進位成 3 月 2 日，所以日期部分再以 UTC 來回一次確認真的存在
const isDate = (v: unknown): v is string =>
  typeof v === "string" && ISO_DATE.test(v) && !Number.isNaN(Date.parse(v)) &&
  new Date(`${v.slice(0, 10)}T00:00:00Z`).toISOString().slice(0, 10) === v.slice(0, 10);
const isText = (v: unknown, max: number) => typeof v === "string" && v.length <= max;

/** 字串或 null 的選填欄位：存在才保留，型別或長度不對時回傳錯誤訊息。 */
function copyOptionalText(from: Fields, to: Fields, key: string, max: number): string | null {
  if (!(key in from)) return null;
  const v = from[key];
  if (v !== null && !isText(v, max)) return `${key} 必須是 ${max} 字以內的字串或 null`;
  to[key] = v;
  return null;
}

function sanitizeWindow(w: unknown): Result<Fields> {
  if (!isObject(w)) return fail("額度必須是物件");
  if (typeof w.id !== "string" || w.id === "" || w.id.length > LIMITS.id) return fail("額度缺少 id");
  if (!isText(w.label, LIMITS.label)) return fail("額度缺少 label");
  const pct = w.used_pct;
  if (typeof pct !== "number" || !Number.isFinite(pct) || pct < 0 || pct > LIMITS.maxPct) return fail("used_pct 不合法");
  if (w.resets_at !== null && w.resets_at !== undefined && !isDate(w.resets_at)) return fail("resets_at 不是日期");
  const window: Fields = { id: w.id, label: w.label, used_pct: pct, resets_at: w.resets_at ?? null };
  if ("hidden" in w) {
    if (typeof w.hidden !== "boolean") return fail("hidden 必須是布林值");
    window.hidden = w.hidden;
  }
  const forecast = sanitizeForecast(w.forecast);
  if (forecast) window.forecast = forecast;
  return { ok: true, value: window };
}

/** 選填的額度預測 `{exhausts_at, urgent, faster?}`（ADR-0018 第 2 節）。附加資訊：格式不符時丟掉這個欄位，
 *  不擋下整份快照。 */
function sanitizeForecast(f: unknown): Fields | null {
  if (!isObject(f) || !isDate(f.exhausts_at) || typeof f.urgent !== "boolean") return null;
  const forecast: Fields = { exhausts_at: f.exhausts_at, urgent: f.urgent };
  if (typeof f.faster === "number" && Number.isFinite(f.faster) && f.faster > 0 && f.faster <= LIMITS.faster) {
    forecast.faster = f.faster;
  }
  return forecast;
}

/** 選填的進行中事故 `[{name, impact, url?, started_at?}]`（ADR-0018 第 4 節）。附加資訊：不是陣列時丟掉欄位、
 *  格式不符的項目略過，不擋下整份快照；空陣列保留（代表查過、沒有事故）。 */
function sanitizeIncidents(list: unknown): Fields[] | null {
  if (!Array.isArray(list)) return null;
  const incidents: Fields[] = [];
  for (const i of list) {
    if (incidents.length >= LIMITS.incidents) break;
    if (!isObject(i) || typeof i.name !== "string" || i.name === "" || !isText(i.name, LIMITS.incidentName)) continue;
    if (typeof i.impact !== "string" || !IMPACTS.includes(i.impact)) continue;
    const incident: Fields = { name: i.name, impact: i.impact };
    if (typeof i.url === "string" && INCIDENT_URL.test(i.url)) incident.url = i.url;
    if (isDate(i.started_at)) incident.started_at = i.started_at;
    incidents.push(incident);
  }
  return incidents;
}

/** 選填的重置次數卷：`{available, credits: [{expires_at, count}]}`（依到期時間分組；沒有 count 的舊格式當 1 張），
 *  只保留張數與到期時間。 */
function sanitizeResetCredits(r: unknown): Result<Fields> {
  if (!isObject(r)) return fail("reset_credits 必須是物件");
  const available = r.available;
  if (!Number.isInteger(available) || (available as number) < 0 || (available as number) > LIMITS.resetCredits) {
    return fail("reset_credits.available 不合法");
  }
  const credits = r.credits ?? [];
  if (!Array.isArray(credits) || credits.length > LIMITS.resetCreditDetails) {
    return fail(`reset_credits.credits 必須是最多 ${LIMITS.resetCreditDetails} 項的陣列`);
  }
  const details: Fields[] = [];
  for (const c of credits) {
    if (!isObject(c)) return fail("重置卷必須是物件");
    if (c.expires_at !== null && c.expires_at !== undefined && !isDate(c.expires_at)) return fail("expires_at 不是日期");
    const detail: Fields = { expires_at: c.expires_at ?? null };
    if ("count" in c) {
      if (!Number.isInteger(c.count) || (c.count as number) < 1 || (c.count as number) > LIMITS.resetCredits) {
        return fail("重置卷的 count 不合法");
      }
      detail.count = c.count;
    }
    details.push(detail);
  }
  return { ok: true, value: { available, credits: details } };
}

function sanitizeProvider(p: unknown): Result<Fields> {
  if (!isObject(p)) return fail("服務必須是物件");
  const provider: Fields = {};
  const invalid = copyOptionalText(p, provider, "plan", LIMITS.plan) ?? copyOptionalText(p, provider, "error", LIMITS.error);
  if (invalid) return fail(invalid);
  const windows = p.windows ?? [];
  if (!Array.isArray(windows) || windows.length > LIMITS.windows) return fail(`windows 必須是最多 ${LIMITS.windows} 項的陣列`);
  provider.windows = [];
  for (const w of windows) {
    const window = sanitizeWindow(w);
    if (!window.ok) return window;
    (provider.windows as Fields[]).push(window.value);
  }
  if (p.reset_credits !== undefined && p.reset_credits !== null) {
    const resetCredits = sanitizeResetCredits(p.reset_credits);
    if (!resetCredits.ok) return resetCredits;
    provider.reset_credits = resetCredits.value;
  }
  const incidents = sanitizeIncidents(p.incidents);
  if (incidents) provider.incidents = incidents;
  return { ok: true, value: provider };
}

/**
 * 驗證快照並以白名單重建（C-12）：只保存 schema 定義的欄位，未知欄位一律移除，
 * 即使收集器出錯誤帶 token 或其他資料也不會被保存、被讀取端拿到（README「隱私與安全」）。
 * 收集器在同一個 schema_version 新增欄位時，要先更新這裡並部署，否則新欄位會被丟掉。
 */
export function sanitizeSnapshot(data: unknown): Result<Fields> {
  if (!isObject(data)) return fail("內容必須是 JSON 物件");
  if (!SUPPORTED_SCHEMA_VERSIONS.includes(data.schema_version as number)) return fail("不支援的 schema_version");
  if (!isDate(data.updated_at)) return fail("缺少 updated_at 或不是日期");
  if (!isObject(data.providers)) return fail("缺少 providers");
  const entries = Object.entries(data.providers);
  if (entries.length > LIMITS.providers) return fail(`服務最多 ${LIMITS.providers} 個`);
  const providers: Fields = {};
  for (const [key, value] of entries) {
    if (!PROVIDER_KEY.test(key)) return fail("服務名稱不合法");
    const provider = sanitizeProvider(value);
    if (!provider.ok) return fail(`${key}：${provider.error}`);
    providers[key] = provider.value;
  }
  return { ok: true, value: { schema_version: data.schema_version, updated_at: data.updated_at, providers } };
}

async function handlePost(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env.WRITE_TOKEN))) return error(401, "unauthorized");

  const body = await request.text();
  if (new TextEncoder().encode(body).length > MAX_BODY_BYTES) return error(413, "內容過大");

  let data: unknown;
  try {
    data = JSON.parse(body);
  } catch {
    return error(400, "內容不是合法的 JSON");
  }
  const snapshot = sanitizeSnapshot(data);
  if (!snapshot.ok) return error(422, snapshot.error);

  // 只存白名單重建後的內容
  await env.USAGE_KV.put(LATEST_KEY, JSON.stringify(snapshot.value));
  return new Response(null, { status: 204 });
}

async function handleGet(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env.READ_TOKEN))) return error(401, "unauthorized");
  const latest = await env.USAGE_KV.get(LATEST_KEY);
  if (latest === null) return error(404, "尚無資料");
  return new Response(latest, {
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

// MARK: iPhone 配對（ADR-0012「短碼」）

// Crockford base32（不含 I、L、O、U）；256 是 32 的倍數，取低 5 位元沒有偏差
const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const PAIRING = { length: 8, ttlSeconds: 600, maxFailures: 5, maxClaimBytes: 1024 };
const PAIR_KEY = "pair";
// KV 的 expirationTtl 最少 60 秒；到期以 expires_at 為準，TTL 只是讓舊資料自動消失
const KV_MIN_TTL = 60;

type PairRecord = { hash: string; expires_at: number };

// 失敗次數存在每組短碼自己的鍵：錯誤的請求從不寫回 PAIR_KEY，晚到的寫入不會讓已兌換或已取代的短碼復活（Codex C-01）
const failKey = (hash: string) => `pair-fail:${hash.slice(0, 16)}`;

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** 與 iPhone 的 PairingCode.normalize 相同：忽略大小寫、空白與連字號，O→0、I／L→1 */
export function normalizeCode(input: string): string | null {
  const mapped = input.toUpperCase().replace(/[\s-]/g, "").replace(/O/g, "0").replace(/[IL]/g, "1");
  if (mapped.length !== PAIRING.length || [...mapped].some((c) => !CODE_ALPHABET.includes(c))) return null;
  return mapped;
}

function newCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(PAIRING.length));
  return [...bytes].map((b) => CODE_ALPHABET[b & 31]).join("");
}

function pairTtl(record: PairRecord, now: number): number {
  return Math.max(KV_MIN_TTL, Math.ceil((record.expires_at - now) / 1000));
}

/**
 * KV 沒有條件刪除：刪之前再讀一次，只刪仍是同一組的短碼，縮小誤刪 Mac 剛發的新碼的機會。
 * 再讀與刪除之間仍有空窗（Codex C-02）；新碼被刪時 Mac 重新產生一組即可。
 */
async function deletePairIfCurrent(env: Env, hash: string): Promise<void> {
  const stored = await env.USAGE_KV.get(PAIR_KEY);
  if (stored === null) return;
  try {
    if ((JSON.parse(stored) as PairRecord).hash !== hash) return;
  } catch {
    // 壞掉的紀錄直接刪
  }
  await env.USAGE_KV.delete(PAIR_KEY);
}

/** Mac 以寫入密鑰要一組短碼；同一時間只有一組，再要一組就取代舊的。只存雜湊。 */
async function handlePair(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env.WRITE_TOKEN))) return error(401, "unauthorized");
  const now = Date.now();
  const code = newCode();
  const record: PairRecord = { hash: await sha256Hex(code), expires_at: now + PAIRING.ttlSeconds * 1000 };
  await env.USAGE_KV.put(PAIR_KEY, JSON.stringify(record), { expirationTtl: pairTtl(record, now) });
  return json({ code, expires_at: new Date(record.expires_at).toISOString().replace(/\.\d{3}Z$/, "Z") });
}

/** 邊讀邊算原始位元組，超過上限就停止讀取並回 null（不先把整份內容讀進記憶體；Codex C-02） */
export async function readLimited(request: Request, maxBytes: number): Promise<string | null> {
  const declared = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declared) && declared > maxBytes) return null;
  if (request.body === null) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

/**
 * iPhone 以短碼兌換讀取密鑰。錯誤、到期、沒有短碼、格式不對都回 403（不區分，避免探測）；
 * 錯 5 次就刪除，成功立即刪除。KV 沒有原子操作：同時送出的正確請求可能都兌換成功（README「已知限制」，Codex C-01）。
 */
async function handleClaim(request: Request, env: Env): Promise<Response> {
  const denied = () => error(403, "配對失敗");
  const body = await readLimited(request, PAIRING.maxClaimBytes);
  if (body === null) return error(413, "內容過大");
  let code: string | null = null;
  try {
    const data: unknown = JSON.parse(body);
    if (isObject(data) && typeof data.code === "string") code = normalizeCode(data.code);
  } catch {
    // 與錯誤的短碼相同處理
  }

  // 格式不對的不讀 KV、不算錯誤次數：不能用垃圾請求消耗 KV 用量或作廢進行中的配對（Fable F-01）
  if (code === null) return denied();
  const stored = await env.USAGE_KV.get(PAIR_KEY);
  if (stored === null) return denied();
  let record: PairRecord;
  try {
    record = JSON.parse(stored) as PairRecord;
  } catch {
    await env.USAGE_KV.delete(PAIR_KEY);
    return denied();
  }
  const now = Date.now();
  if (!(record.expires_at > now)) {
    await deletePairIfCurrent(env, record.hash);
    return denied();
  }
  const failures = Number(await env.USAGE_KV.get(failKey(record.hash))) || 0;
  if (failures >= PAIRING.maxFailures) {
    await deletePairIfCurrent(env, record.hash);
    return denied();
  }
  if (await safeEqual(await sha256Hex(code), record.hash)) {
    await deletePairIfCurrent(env, record.hash);
    return json({ read_token: env.READ_TOKEN });
  }
  if (failures + 1 >= PAIRING.maxFailures) await deletePairIfCurrent(env, record.hash);
  await env.USAGE_KV.put(failKey(record.hash), String(failures + 1), { expirationTtl: pairTtl(record, now) });
  return denied();
}

const ROUTES: Record<string, Partial<Record<string, (request: Request, env: Env) => Promise<Response>>>> = {
  "/usage": { GET: handleGet, POST: handlePost },
  "/pair": { POST: handlePair },
  "/pair/claim": { POST: handleClaim },
};

export default {
  /** 每月排程（wrangler.toml 的 crons）：刪除第二層 400 天以前的每日加總；沒有 D1 綁定時什麼都不做 */
  async scheduled(_controller: unknown, env: Env): Promise<void> {
    if (!env.DB) return;
    const deleted = await pruneOldDays(env.DB, Date.now());
    console.log(`第二層：刪除 ${deleted} 列 ${OLDEST_DAYS} 天以前的每日加總`);
  },

  async fetch(request: Request, env: Env): Promise<Response> {
    // 兩把密鑰都要設定且不同，否則拒絕服務，避免讀取密鑰也能寫入
    if (!env.READ_TOKEN || !env.WRITE_TOKEN || env.READ_TOKEN === env.WRITE_TOKEN) {
      return error(500, "relay 密鑰設定錯誤");
    }

    const tier2 = await handleTier2(request, env);
    if (tier2) return tier2;

    const { pathname } = new URL(request.url);
    const route = Object.hasOwn(ROUTES, pathname) ? ROUTES[pathname] : undefined;
    if (!route) return error(404, "not found");
    const handler = Object.hasOwn(route, request.method) ? route[request.method] : undefined;
    if (!handler) return new Response(null, { status: 405, headers: { Allow: Object.keys(route).join(", ") } });
    return handler(request, env);
  },
};
