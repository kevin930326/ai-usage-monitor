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

/** 只檢查 iOS 端依賴的骨架，細節欄位交給 schema_version 管理。 */
export function validateSnapshot(data: unknown): string | null {
  if (typeof data !== "object" || data === null || Array.isArray(data)) return "內容必須是 JSON 物件";
  const snap = data as Record<string, unknown>;
  if (!SUPPORTED_SCHEMA_VERSIONS.includes(snap.schema_version as number)) return "不支援的 schema_version";
  if (typeof snap.updated_at !== "string") return "缺少 updated_at";
  if (typeof snap.providers !== "object" || snap.providers === null) return "缺少 providers";
  return null;
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
  const invalid = validateSnapshot(data);
  if (invalid) return error(422, invalid);

  // 重新序列化，只存解析過的內容
  await env.USAGE_KV.put(LATEST_KEY, JSON.stringify(data));
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
