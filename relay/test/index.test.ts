import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import worker, { MAX_BODY_BYTES, type Env } from "../src/index.ts";

class MemoryKV {
  store = new Map<string, string>();
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string) {
    this.store.set(key, value);
  }
}

const SNAPSHOT = {
  schema_version: 1,
  updated_at: "2026-10-21T00:00:00Z",
  providers: { claude: { plan: "Max", error: null, windows: [] } },
};

let kv: MemoryKV;
let env: Env;

function call(method: string, token?: string, body?: string, path = "/usage") {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  return worker.fetch(new Request(`https://relay.test${path}`, { method, headers, body }), env);
}

beforeEach(() => {
  kv = new MemoryKV();
  env = { USAGE_KV: kv, READ_TOKEN: "read-secret", WRITE_TOKEN: "write-secret" };
});

describe("POST /usage", () => {
  it("用寫入密鑰上傳後可以用讀取密鑰讀到", async () => {
    const post = await call("POST", "write-secret", JSON.stringify(SNAPSHOT));
    assert.equal(post.status, 204);

    const get = await call("GET", "read-secret");
    assert.equal(get.status, 200);
    assert.equal(get.headers.get("Cache-Control"), "no-store");
    assert.deepEqual(await get.json(), SNAPSHOT);
  });

  it("讀取密鑰不能寫入", async () => {
    const res = await call("POST", "read-secret", JSON.stringify(SNAPSHOT));
    assert.equal(res.status, 401);
    assert.equal(kv.store.size, 0);
  });

  it("拒絕不合法的 JSON", async () => {
    assert.equal((await call("POST", "write-secret", "{not json")).status, 400);
  });

  it("拒絕不支援的 schema_version", async () => {
    const res = await call("POST", "write-secret", JSON.stringify({ ...SNAPSHOT, schema_version: 99 }));
    assert.equal(res.status, 422);
  });

  it("拒絕缺少 providers 的內容", async () => {
    const { providers, ...rest } = SNAPSHOT;
    assert.equal((await call("POST", "write-secret", JSON.stringify(rest))).status, 422);
  });

  it("接受沒有啟用任何服務的快照（providers 為空物件不是錯誤）", async () => {
    const empty = { ...SNAPSHOT, providers: {} };
    assert.equal((await call("POST", "write-secret", JSON.stringify(empty))).status, 204);
    assert.deepEqual(await (await call("GET", "read-secret")).json(), empty);
  });

  it("LIMITS 允許的最大快照不會被 body 上限擋下", async () => {
    const window = (i: number) => ({ id: `weekly_model_${i}`, label: `每週 Model ${i}`, used_pct: 100, resets_at: "2026-10-21T05:00:00Z", hidden: true });
    const provider = { plan: "Max", error: null, windows: Array.from({ length: 16 }, (_, i) => window(i)) };
    const full = { ...SNAPSHOT, providers: Object.fromEntries(Array.from({ length: 8 }, (_, i) => [`provider_${i}`, provider])) };
    assert.equal((await call("POST", "write-secret", JSON.stringify(full))).status, 204);
  });

  it("拒絕過大的內容", async () => {
    const big = JSON.stringify({ ...SNAPSHOT, pad: "x".repeat(MAX_BODY_BYTES) });
    assert.equal((await call("POST", "write-secret", big)).status, 413);
  });
});

describe("POST /usage 欄位驗證（C-12）", () => {
  const WINDOW = { id: "five_hour", label: "5 小時", used_pct: 12.5, resets_at: "2026-10-21T05:00:00Z", hidden: false };
  const snapshot = (provider: Record<string, unknown>, extra: Record<string, unknown> = {}) =>
    JSON.stringify({ ...SNAPSHOT, ...extra, providers: { claude: { plan: "Max", error: null, windows: [WINDOW], ...provider } } });
  const post = (body: string) => call("POST", "write-secret", body);

  it("只保存允許的欄位，未知欄位（例如誤帶的 token）被移除", async () => {
    const body = snapshot(
      { access_token: "leak", windows: [{ ...WINDOW, email: "me@example.com" }] },
      { refresh_token: "leak" },
    );
    assert.equal((await post(body)).status, 204);
    const stored = kv.store.get("latest")!;
    assert.ok(!stored.includes("leak") && !stored.includes("example.com"), stored);
    assert.deepEqual(await (await call("GET", "read-secret")).json(), {
      ...SNAPSHOT,
      providers: { claude: { plan: "Max", error: null, windows: [WINDOW] } },
    });
  });

  it("沒有 hidden 的舊版額度照樣保存", async () => {
    const { hidden, ...old } = WINDOW;
    assert.equal((await post(snapshot({ windows: [old] }))).status, 204);
    assert.deepEqual((await (await call("GET", "read-secret")).json()).providers.claude.windows, [old]);
  });

  const invalid: [string, string][] = [
    ["providers 是陣列", JSON.stringify({ ...SNAPSHOT, providers: [] })],
    ["updated_at 不是日期", JSON.stringify({ ...SNAPSHOT, updated_at: "昨天" })],
    ["updated_at 不存在的日期", JSON.stringify({ ...SNAPSHOT, updated_at: "2026-13-45T00:00:00Z" })],
    ["服務不是物件", JSON.stringify({ ...SNAPSHOT, providers: { claude: "x" } })],
    ["服務名稱不合法", JSON.stringify({ ...SNAPSHOT, providers: { "<script>": { windows: [] } } })],
    ["windows 不是陣列", snapshot({ windows: {} })],
    ["used_pct 是字串", snapshot({ windows: [{ ...WINDOW, used_pct: "12" }] })],
    ["used_pct 是負數", snapshot({ windows: [{ ...WINDOW, used_pct: -1 }] })],
    ["used_pct 缺少", snapshot({ windows: [{ id: "five_hour", label: "5 小時", resets_at: null }] })],
    ["resets_at 不是日期", snapshot({ windows: [{ ...WINDOW, resets_at: "soon" }] })],
    ["hidden 不是布林", snapshot({ windows: [{ ...WINDOW, hidden: "no" }] })],
    ["錯誤訊息過長", snapshot({ error: "錯".repeat(501) })],
    ["plan 不是字串", snapshot({ plan: 3 })],
    ["額度過多", snapshot({ windows: Array.from({ length: 17 }, (_, i) => ({ ...WINDOW, id: `w${i}` })) })],
    [
      "服務過多",
      JSON.stringify({
        ...SNAPSHOT,
        providers: Object.fromEntries(Array.from({ length: 9 }, (_, i) => [`p${i}`, { windows: [] }])),
      }),
    ],
  ];
  for (const [name, body] of invalid) {
    it(`拒絕：${name}`, async () => {
      assert.equal((await post(body)).status, 422);
      assert.equal(kv.store.size, 0);
    });
  }
});

describe("GET /usage", () => {
  it("沒有密鑰或密鑰錯誤回 401", async () => {
    assert.equal((await call("GET")).status, 401);
    assert.equal((await call("GET", "wrong")).status, 401);
    assert.equal((await call("GET", "write-secret")).status, 401);
  });

  it("尚未上傳時回 404", async () => {
    assert.equal((await call("GET", "read-secret")).status, 404);
  });
});

describe("路由與設定", () => {
  it("其他路徑回 404、其他方法回 405", async () => {
    assert.equal((await call("GET", "read-secret", undefined, "/other")).status, 404);
    const res = await call("DELETE", "write-secret");
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("Allow"), "GET, POST");
  });

  it("讀寫密鑰相同時拒絕服務", async () => {
    env.READ_TOKEN = env.WRITE_TOKEN;
    assert.equal((await call("GET", "write-secret")).status, 500);
  });

  it("缺少密鑰設定時拒絕服務", async () => {
    env.READ_TOKEN = "";
    assert.equal((await call("GET", "")).status, 500);
  });
});
