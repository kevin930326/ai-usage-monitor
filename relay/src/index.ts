/**
 * 中繼 API：Mac 收集器上傳最新一筆用量，iPhone 讀取（FR-6、ADR-0001）。
 *
 *   POST /usage  Authorization: Bearer <WRITE_TOKEN>
 *   GET  /usage  Authorization: Bearer <READ_TOKEN>
 */

export interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}

export interface Env {
  USAGE_KV: KV;
  READ_TOKEN: string;
  WRITE_TOKEN: string;
}

export const SUPPORTED_SCHEMA_VERSIONS = [1];
export const MAX_BODY_BYTES = 16 * 1024;
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
export const LIMITS = { providers: 8, windows: 16, plan: 64, error: 500, id: 64, label: 64, maxPct: 1000 };
const PROVIDER_KEY = /^[a-z0-9_-]{1,32}$/;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

type Fields = Record<string, unknown>;
type Result<T> = { ok: true; value: T } | { ok: false; error: string };

const fail = (error: string): { ok: false; error: string } => ({ ok: false, error });
const isObject = (v: unknown): v is Fields => typeof v === "object" && v !== null && !Array.isArray(v);
const isDate = (v: unknown): v is string => typeof v === "string" && ISO_DATE.test(v) && !Number.isNaN(Date.parse(v));
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
  return { ok: true, value: window };
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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // 兩把密鑰都要設定且不同，否則拒絕服務，避免讀取密鑰也能寫入
    if (!env.READ_TOKEN || !env.WRITE_TOKEN || env.READ_TOKEN === env.WRITE_TOKEN) {
      return error(500, "relay 密鑰設定錯誤");
    }

    const { pathname } = new URL(request.url);
    if (pathname !== "/usage") return error(404, "not found");

    switch (request.method) {
      case "GET":
        return handleGet(request, env);
      case "POST":
        return handlePost(request, env);
      default:
        return new Response(null, { status: 405, headers: { Allow: "GET, POST" } });
    }
  },
};
