import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import worker, { type Env } from "../src/index.ts";

// 收集器與 App 的測試讀同一份（fixtures/README.md）
const read = (name: string) => readFileSync(new URL(`../../fixtures/${name}`, import.meta.url), "utf8");
const FIXTURE = read("usage-sample.json");

class MemoryKV {
  store = new Map<string, string>();
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string) {
    this.store.set(key, value);
  }
}

async function roundTrip(body: string) {
  const env: Env = { USAGE_KV: new MemoryKV(), READ_TOKEN: "read-secret", WRITE_TOKEN: "write-secret" };
  const call = (method: string, token: string, payload?: string) =>
    worker.fetch(
      new Request("https://relay.test/usage", { method, headers: { Authorization: `Bearer ${token}` }, body: payload }),
      env,
    );

  assert.equal((await call("POST", "write-secret", body)).status, 204);
  const get = await call("GET", "read-secret");
  assert.equal(get.status, 200);
  assert.deepEqual(await get.json(), JSON.parse(body));
}

describe("共用 fixture", () => {
  it("上傳後原樣讀回（含 hidden 額度、null 的 resets_at 與失敗的服務）", async () => {
    await roundTrip(FIXTURE);
  });

  // 整合審查 D-i：只有 Codex、plan 為 null、已用超過 100%
  it("只有 Codex 的快照原樣讀回（plan null、used_pct 112.5）", async () => {
    await roundTrip(read("usage-codex-only.json"));
  });

  it("沒有任何服務的快照原樣讀回（providers 為空）", async () => {
    await roundTrip(read("usage-no-providers.json"));
  });
});
