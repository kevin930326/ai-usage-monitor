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

  it("拒絕過大的內容", async () => {
    const big = JSON.stringify({ ...SNAPSHOT, pad: "x".repeat(MAX_BODY_BYTES) });
    assert.equal((await call("POST", "write-secret", big)).status, 413);
  });
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
