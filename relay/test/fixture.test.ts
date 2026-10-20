import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import worker, { type Env } from "../src/index.ts";

// 收集器與 App 的測試讀同一份（fixtures/README.md）
const FIXTURE = readFileSync(new URL("../../fixtures/usage-sample.json", import.meta.url), "utf8");

class MemoryKV {
  store = new Map<string, string>();
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string) {
    this.store.set(key, value);
  }
}

describe("共用 fixture", () => {
  it("上傳後原樣讀回（含 hidden 額度、null 的 resets_at 與失敗的服務）", async () => {
    const env: Env = { USAGE_KV: new MemoryKV(), READ_TOKEN: "read-secret", WRITE_TOKEN: "write-secret" };
    const call = (method: string, token: string, body?: string) =>
      worker.fetch(
        new Request("https://relay.test/usage", { method, headers: { Authorization: `Bearer ${token}` }, body }),
        env,
      );

    assert.equal((await call("POST", "write-secret", FIXTURE)).status, 204);
    const get = await call("GET", "read-secret");
    assert.equal(get.status, 200);
    assert.deepEqual(await get.json(), JSON.parse(FIXTURE));
  });
});
