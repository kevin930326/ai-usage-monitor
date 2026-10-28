import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { AGENT_MAX_AGE_MS, handleAgents, MAX_AGENT_BODY_BYTES } from "../src/agents.ts";
import worker, { type Env } from "../src/index.ts";
import { FakeD1 } from "./fake-d1.ts";

let db: FakeD1;
let env: Env;

function request(method: string, token?: string, body?: unknown) {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const text = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
  return new Request("https://relay.test/agents/state", { method, headers, body: text });
}

const call = (method: string, token?: string, body?: unknown) => worker.fetch(request(method, token, body), env);
/** 指定中繼的時間 */
const at = (now: number, method: string, token?: string, body?: unknown) => handleAgents(request(method, token, body), env, now) as Promise<Response>;

async function addDevice(name: string) {
  const res = await worker.fetch(
    new Request("https://relay.test/devices", { method: "POST", headers: { Authorization: "Bearer admin-secret" }, body: JSON.stringify({ name }) }),
    env,
  );
  assert.equal(res.status, 201);
  return (await res.json()) as { device_id: string; key: string };
}

const row = (over: Record<string, unknown> = {}) => ({ ai: "claude", state: "needsYou", sessions: 1, since: Date.now() - 1000, ...over });

async function download(now?: number) {
  const res = now === undefined ? await call("GET", "read-secret") : await at(now, "GET", "read-secret");
  assert.equal(res.status, 200);
  return (await res.json()) as { now: number; devices: { device_id: string; name: string; ais: Record<string, unknown>[]; updated_at: number }[] };
}

describe("/agents/state", () => {
  beforeEach(() => {
    db = new FakeD1();
    env = { USAGE_KV: { get: async () => null, put: async () => {}, delete: async () => {} }, READ_TOKEN: "read-secret", WRITE_TOKEN: "write-secret", ADMIN_TOKEN: "admin-secret", DB: db, AGENT_SYNC: "on" };
  });

  it("AGENT_SYNC 不是 on 時兩個端點都回 404", async () => {
    const device = await addDevice("桌機");
    for (const value of [undefined, "", "1", "true", "ON"]) {
      env.AGENT_SYNC = value;
      assert.equal((await call("POST", device.key, { ais: [row()] })).status, 404);
      assert.equal((await call("GET", "read-secret")).status, 404);
    }
  });

  it("沒有 D1 綁定時回 503", async () => {
    env.DB = undefined;
    assert.equal((await call("GET", "read-secret")).status, 503);
  });

  it("上傳後其他電腦讀得到，整台覆蓋", async () => {
    const desk = await addDevice("桌機");
    const now = Date.now();
    assert.equal((await at(now, "POST", desk.key, { ais: [row(), row({ ai: "codex", state: "working", sessions: 2 })] })).status, 200);
    let data = await download(now + 1000);
    assert.equal(data.now, now + 1000);
    assert.deepEqual(data.devices.map((d) => [d.device_id, d.name, d.updated_at, d.ais.map((a) => [a.ai, a.state, a.sessions])]), [
      [desk.device_id, "桌機", now, [["claude", "needsYou", 1], ["codex", "working", 2]]],
    ]);
    // 第二次只有 codex：claude 那一列不留
    assert.equal((await at(now + 2000, "POST", desk.key, { ais: [row({ ai: "codex", state: "done" })] })).status, 200);
    data = await download(now + 3000);
    assert.deepEqual(data.devices[0].ais.map((a) => [a.ai, a.state]), [["codex", "done"]]);
    assert.equal(data.devices[0].updated_at, now + 2000);
  });

  it("全部閒置也回傳這台（ais 空的），30 分鐘沒更新就不回傳", async () => {
    const desk = await addDevice("桌機");
    const now = Date.now();
    assert.equal((await at(now, "POST", desk.key, { ais: [] })).status, 200);
    assert.deepEqual((await download(now)).devices.map((d) => [d.name, d.ais]), [["桌機", []]]);
    assert.equal((await download(now + AGENT_MAX_AGE_MS)).devices.length, 1);
    assert.equal((await download(now + AGENT_MAX_AGE_MS + 1)).devices.length, 0);
  });

  it("since 夾在中繼時間的 24 小時內", async () => {
    const desk = await addDevice("桌機");
    const now = 1_800_000_000_000;
    await at(now, "POST", desk.key, { ais: [row({ since: now + 3_600_000 }), row({ ai: "codex", since: 5 })] });
    const ais = (await download(now)).devices[0].ais;
    assert.deepEqual(ais.map((a) => a.since), [now, now - 24 * 3_600_000]);
  });

  it("只收裝置密鑰上傳；讀取只收 READ_TOKEN", async () => {
    const desk = await addDevice("桌機");
    for (const token of [undefined, "read-secret", "write-secret", "admin-secret", "aumd_wrong"]) {
      assert.equal((await call("POST", token, { ais: [row()] })).status, 401);
    }
    for (const token of [undefined, desk.key, "write-secret", "admin-secret"]) {
      assert.equal((await call("GET", token)).status, 401);
    }
    assert.equal((await call("PUT", desk.key, {})).status, 405);
  });

  it("不合法的內容回 422／400／413，不寫入", async () => {
    const desk = await addDevice("桌機");
    const bad: unknown[] = [
      [],
      { rows: [] },
      { ais: [row(), row({ ai: "codex" }), row({ ai: "gemini" })] },
      { ais: [row({ ai: "gemini" })] },
      { ais: [row(), row()] },
      { ais: [row({ state: "approved" })] },
      { ais: [row({ sessions: 33 })] },
      { ais: [row({ sessions: 1.5 })] },
      { ais: [row({ sessions: "1" })] },
      { ais: [row({ since: -1 })] },
      { ais: [row({ since: true })] },
      { ais: ["claude"] },
    ];
    for (const body of bad) assert.equal((await call("POST", desk.key, body)).status, 422, JSON.stringify(body));
    assert.equal((await call("POST", desk.key, "{")).status, 400);
    assert.equal((await call("POST", desk.key, { ais: [], pad: "x".repeat(MAX_AGENT_BODY_BYTES) })).status, 413);
    assert.deepEqual((await download()).devices, []);
  });

  it("只存白名單欄位：上傳內容裡的裝置、名稱、路徑一律不採用", async () => {
    const desk = await addDevice("桌機");
    const other = await addDevice("筆電");
    const res = await call("POST", desk.key, { device_id: other.device_id, ais: [row({ name: "secret-project", cwd: "/Users/someone/secret", device_id: other.device_id })] });
    assert.equal(res.status, 200);
    const dump = db.dump();
    assert.ok(!dump.includes("secret"));
    const data = await download();
    assert.deepEqual(data.devices.map((d) => d.device_id), [desk.device_id]);
    assert.deepEqual(Object.keys(data.devices[0].ais[0]).sort(), ["ai", "sessions", "since", "state"]);
  });

  it("撤銷的裝置不回傳，它的狀態一併刪除；撤銷後舊密鑰不能再寫", async () => {
    const desk = await addDevice("桌機");
    await call("POST", desk.key, { ais: [row()] });
    const res = await worker.fetch(
      new Request(`https://relay.test/devices/${desk.device_id}/revoke`, { method: "POST", headers: { Authorization: "Bearer admin-secret" } }),
      env,
    );
    assert.equal(res.status, 200);
    assert.deepEqual((await download()).devices, []);
    assert.equal((db.db.prepare("SELECT COUNT(*) AS n FROM agent_state").get() as { n: number }).n, 0);
    assert.equal((await call("POST", desk.key, { ais: [row()] })).status, 401);
  });

  it("一次上傳是一個交易", async () => {
    const desk = await addDevice("桌機");
    const before = db.batches;
    await call("POST", desk.key, { ais: [row(), row({ ai: "codex" })] });
    assert.equal(db.batches, before + 1);
  });
});
