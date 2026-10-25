import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import worker, { type Env } from "../src/index.ts";
import { MAX_DOWNLOAD_ROWS, MAX_ROWS, MAX_TOKENS_BODY_BYTES } from "../src/tokens.ts";
import { FakeD1 } from "./fake-d1.ts";

class MemoryKV {
  store = new Map<string, string>();
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string) {
    this.store.set(key, value);
  }
}

let db: FakeD1;
let env: Env;

function call(method: string, path: string, token?: string, body?: unknown) {
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const text = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
  return worker.fetch(new Request(`https://relay.test${path}`, { method, headers, body: text }), env);
}

const today = () => new Date().toISOString().slice(0, 10);
const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);

function row(over: Record<string, unknown> = {}) {
  return {
    day: today(),
    provider: "claude",
    model: "claude-opus-5-5",
    input_tokens: 10,
    cache_write_tokens: 20,
    cache_read_tokens: 300,
    output_tokens: 40,
    reasoning_tokens: 5,
    task_seconds: 60,
    longest_task_seconds: 30,
    ...over,
  };
}

async function addDevice(name = "工作 PC") {
  const res = await call("POST", "/devices", "admin-secret", { name });
  assert.equal(res.status, 201);
  return (await res.json()) as { device_id: string; name: string; key: string };
}

async function upload(key: string, rows: unknown[]) {
  return call("POST", "/tokens/daily", key, { rows });
}

async function download(from = daysAgo(30)) {
  const res = await call("GET", `/tokens/daily?from=${from}`, "read-secret");
  assert.equal(res.status, 200);
  return (await res.json()) as { devices: Record<string, unknown>[]; rows: Record<string, unknown>[] };
}

beforeEach(() => {
  db = new FakeD1();
  env = { USAGE_KV: new MemoryKV(), READ_TOKEN: "read-secret", WRITE_TOKEN: "write-secret", ADMIN_TOKEN: "admin-secret", DB: db };
});

describe("第二層沒有設定", () => {
  it("沒有 D1 綁定時 /tokens/daily 與 /devices 回 503，/usage 照常", async () => {
    delete env.DB;
    assert.equal((await call("POST", "/tokens/daily", "aumd_x", { rows: [] })).status, 503);
    assert.equal((await call("GET", "/devices", "admin-secret")).status, 503);
    const snapshot = { schema_version: 1, updated_at: "2026-10-21T00:00:00Z", providers: {} };
    assert.equal((await call("POST", "/usage", "write-secret", snapshot)).status, 204);
  });

  it("ADMIN_TOKEN 沒設定或和其他密鑰相同時不能管理裝置", async () => {
    delete env.ADMIN_TOKEN;
    assert.equal((await call("POST", "/devices", "admin-secret", { name: "PC" })).status, 503);
    env.ADMIN_TOKEN = "read-secret";
    assert.equal((await call("POST", "/devices", "read-secret", { name: "PC" })).status, 503);
  });
});

describe("裝置管理", () => {
  it("新增時回傳一次密鑰，中繼只存雜湊", async () => {
    const device = await addDevice();
    assert.match(device.key, /^aumd_[A-Za-z0-9_-]{43}$/);
    assert.match(device.device_id, /^[0-9a-f-]{36}$/);
    assert.ok(!db.dump().includes(device.key));
    const list = await (await call("GET", "/devices", "admin-secret")).json();
    assert.deepEqual(Object.keys(list.devices[0]).sort(), ["created_at", "device_id", "last_upload_at", "name", "revoked"]);
    assert.ok(!JSON.stringify(list).includes(device.key));
  });

  it("名稱只收 1～32 字的單行文字", async () => {
    for (const name of ["", "   ", "a".repeat(33), "第一行\n第二行", 42]) {
      assert.equal((await call("POST", "/devices", "admin-secret", { name })).status, 422, String(name));
    }
    assert.equal((await addDevice("  家裡的 PC  ")).name, "家裡的 PC");
  });

  it("只有管理密鑰能管理裝置", async () => {
    const device = await addDevice();
    for (const token of ["read-secret", "write-secret", device.key, undefined]) {
      assert.equal((await call("POST", "/devices", token, { name: "x" })).status, 401);
      assert.equal((await call("GET", "/devices", token)).status, 401);
      assert.equal((await call("POST", `/devices/${device.device_id}/revoke`, token, {})).status, 401);
    }
  });

  it("換密鑰後舊密鑰失效、device_id 不變", async () => {
    const device = await addDevice();
    const res = await call("POST", `/devices/${device.device_id}/rotate`, "admin-secret");
    const rotated = (await res.json()) as { device_id: string; key: string };
    assert.equal(rotated.device_id, device.device_id);
    assert.notEqual(rotated.key, device.key);
    assert.equal((await upload(device.key, [row()])).status, 401);
    const ok = await upload(rotated.key, [row()]);
    assert.equal((await ok.json()).device_id, device.device_id);
  });

  it("撤銷後密鑰失效；資料預設保留，可選擇一併刪除", async () => {
    const keep = await addDevice("留資料");
    const drop = await addDevice("刪資料");
    await upload(keep.key, [row()]);
    await upload(drop.key, [row()]);
    assert.equal((await call("POST", `/devices/${keep.device_id}/revoke`, "admin-secret")).status, 200);
    const res = await call("POST", `/devices/${drop.device_id}/revoke`, "admin-secret", { delete_data: true });
    assert.equal((await res.json()).deleted_data, true);
    assert.equal((await upload(keep.key, [row()])).status, 401);
    assert.equal((await upload(drop.key, [row()])).status, 401);
    // 撤銷了也不能換密鑰重新啟用
    assert.equal((await call("POST", `/devices/${keep.device_id}/rotate`, "admin-secret")).status, 409);
    const data = await download();
    assert.deepEqual(data.rows.map((r) => r.device_id), [keep.device_id]);
    assert.deepEqual(data.devices.map((d) => [d.name, d.revoked, d.has_data]), [["留資料", true, true], ["刪資料", true, false]]);
    // has_data 不受 from 限制：只有很久以前的資料也算有
    const later = await download(daysAgo(-1));
    assert.deepEqual(later.rows, []);
    assert.equal(later.devices[0].has_data, true);
  });

  it("不存在的裝置與格式錯誤的 delete_data", async () => {
    assert.equal((await call("POST", "/devices/00000000-0000-4000-8000-000000000000/revoke", "admin-secret")).status, 404);
    assert.equal((await call("POST", "/devices/not-an-id/revoke", "admin-secret")).status, 404);
    const device = await addDevice();
    assert.equal((await call("POST", `/devices/${device.device_id}/revoke`, "admin-secret", { delete_data: "yes" })).status, 422);
  });
});

describe("POST /tokens/daily", () => {
  it("以 (裝置、日期、服務、模型) 覆蓋寫入：重送不會重複計算", async () => {
    const device = await addDevice();
    for (let i = 0; i < 3; i++) assert.equal((await upload(device.key, [row()])).status, 200);
    assert.equal(db.rows().length, 1);
    await upload(device.key, [row({ input_tokens: 15 })]);
    const rows = db.rows();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].input_tokens, 15);
    assert.equal(rows[0].output_tokens, 40);
  });

  it("device_id 由密鑰決定，內容中的裝置欄位與其他欄位都丟掉", async () => {
    const a = await addDevice("A");
    const b = await addDevice("B");
    const res = await upload(a.key, [row({ device_id: b.device_id, cwd: "/Users/someone/project", session_id: "s" })]);
    assert.deepEqual(await res.json(), { device_id: a.device_id, accepted: 1 });
    const rows = db.rows();
    assert.equal(rows[0].device_id, a.device_id);
    assert.ok(!db.dump().includes("/Users/someone"));
    assert.deepEqual(Object.keys(rows[0]).sort(), [
      "cache_read_tokens", "cache_write_tokens", "day", "device_id", "input_tokens", "longest_task_seconds",
      "model", "output_tokens", "provider", "reasoning_tokens", "task_seconds", "updated_at",
    ]);
  });

  it("兩台裝置的同一天各自保存，不會互相覆蓋", async () => {
    const a = await addDevice("A");
    const b = await addDevice("B");
    await upload(a.key, [row({ input_tokens: 1 })]);
    await upload(b.key, [row({ input_tokens: 2 })]);
    assert.deepEqual(db.rows().map((r) => r.input_tokens).sort(), [1, 2]);
  });

  it("一次上傳在同一個交易中寫入，並記錄最後上傳時間；空的一批也回傳 device_id", async () => {
    const device = await addDevice();
    const res = await upload(device.key, []);
    assert.deepEqual(await res.json(), { device_id: device.device_id, accepted: 0 });
    await upload(device.key, [row(), row({ provider: "codex", model: "gpt-6.1-sol" })]);
    assert.equal(db.batches, 2);
    const data = await download();
    assert.match(String(data.devices[0].last_upload_at), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });

  it("只有裝置密鑰能上傳；裝置密鑰不能寫 /usage、不能下載", async () => {
    const device = await addDevice();
    for (const token of ["read-secret", "write-secret", "admin-secret", "aumd_unknown", undefined]) {
      assert.equal((await upload(token as string, [row()])).status, 401, String(token));
    }
    const snapshot = { schema_version: 1, updated_at: "2026-10-21T00:00:00Z", providers: {} };
    assert.equal((await call("POST", "/usage", device.key, snapshot)).status, 401);
    assert.equal((await call("GET", `/tokens/daily?from=${today()}`, device.key)).status, 401);
    assert.equal(db.rows().length, 0);
  });

  it("驗證之後、寫入之前被撤銷（刪除資料）或換新密鑰的上傳不寫回資料", async () => {
    for (const action of ["revoke", "rotate"]) {
      db = new FakeD1();
      env.DB = db;
      const device = await addDevice();
      assert.equal((await upload(device.key, [row({ day: daysAgo(1) })])).status, 200);
      // 內容晚一點才送到：Worker 已經查過密鑰、正在等內容
      let release = () => {};
      const gate = new Promise<void>((resolve) => (release = resolve));
      const body = new ReadableStream({
        async start(controller) {
          await gate;
          controller.enqueue(new TextEncoder().encode(JSON.stringify({ rows: [row()] })));
          controller.close();
        },
      });
      const init = { method: "POST", headers: { Authorization: `Bearer ${device.key}` }, body, duplex: "half" };
      const pending = worker.fetch(new Request("https://relay.test/tokens/daily", init as RequestInit), env);
      await new Promise((resolve) => setTimeout(resolve, 20));
      const admin = action === "revoke"
        ? await call("POST", `/devices/${device.device_id}/revoke`, "admin-secret", { delete_data: true })
        : await call("POST", `/devices/${device.device_id}/rotate`, "admin-secret");
      assert.equal(admin.status, 200);
      release();
      assert.equal((await pending).status, 401, action);
      assert.deepEqual(db.rows().map((r) => r.day), action === "revoke" ? [] : [daysAgo(1)], action);
    }
  });

  it("驗證每一列", async () => {
    const device = await addDevice();
    const bad = [
      row({ day: "2026-02-30" }),
      row({ day: "2026-13-01" }),
      row({ day: "2026-00-10" }),
      row({ day: "2026/10/01" }),
      row({ day: daysAgo(401) }),
      row({ day: daysAgo(-2) }),
      row({ provider: "gemini" }),
      row({ model: "my secret project" }),
      row({ model: `claude-${"x".repeat(60)}` }),
      row({ input_tokens: -1 }),
      row({ input_tokens: 1.5 }),
      row({ input_tokens: "10" }),
      row({ output_tokens: 1e12 + 1 }),
      "not an object",
    ];
    for (const r of bad) assert.equal((await upload(device.key, [r])).status, 422, JSON.stringify(r));
    // 全批拒絕：前面合格的列也不寫入
    assert.equal((await upload(device.key, [row(), row({ provider: "x" })])).status, 422);
    assert.equal(db.rows().length, 0);
    // 合格的邊界
    for (const r of [row({ day: daysAgo(400) }), row({ day: daysAgo(-1) }), row({ model: "other" }), row({ output_tokens: 1e12 })]) {
      assert.equal((await upload(device.key, [r])).status, 200, JSON.stringify(r));
    }
  });

  it("沒給的數值當成 0", async () => {
    const device = await addDevice();
    await upload(device.key, [{ day: today(), provider: "codex", model: "gpt-6.1-sol", output_tokens: 7 }]);
    assert.equal(db.rows()[0].input_tokens, 0);
    assert.equal(db.rows()[0].output_tokens, 7);
  });

  it("批次大小、重複列、內容大小與 JSON 格式", async () => {
    const device = await addDevice();
    const many = Array.from({ length: MAX_ROWS + 1 }, (_, i) => row({ model: `claude-m${i}` }));
    assert.equal((await upload(device.key, many)).status, 422);
    assert.equal((await upload(device.key, many.slice(0, MAX_ROWS))).status, 200);
    assert.equal((await upload(device.key, [row(), row()])).status, 422);
    assert.equal((await call("POST", "/tokens/daily", device.key, "x".repeat(MAX_TOKENS_BODY_BYTES + 1))).status, 413);
    assert.equal((await call("POST", "/tokens/daily", device.key, "{not json")).status, 400);
    assert.equal((await call("POST", "/tokens/daily", device.key, { rows: "x" })).status, 422);
  });
});

describe("GET /tokens/daily", () => {
  it("用讀取密鑰下載所有裝置的列與裝置清單（不含密鑰）", async () => {
    const a = await addDevice("Mac");
    const b = await addDevice("PC");
    await upload(a.key, [row({ day: daysAgo(3) }), row({ day: daysAgo(40) })]);
    await upload(b.key, [row({ day: daysAgo(1), provider: "codex", model: "gpt-6.1-sol" })]);
    const data = await download(daysAgo(30));
    assert.deepEqual(data.rows.map((r) => [r.device_id, r.day]), [[a.device_id, daysAgo(3)], [b.device_id, daysAgo(1)]]);
    assert.deepEqual(data.devices.map((d) => d.name), ["Mac", "PC"]);
    assert.ok(!JSON.stringify(data).includes(a.key) && !JSON.stringify(data).includes("key_hash"));
    assert.equal(data.rows[0].updated_at, undefined);
  });

  it("只有讀取密鑰能下載；from 必須是日期", async () => {
    for (const token of ["write-secret", "admin-secret", undefined]) {
      assert.equal((await call("GET", `/tokens/daily?from=${today()}`, token)).status, 401);
    }
    assert.equal((await call("GET", "/tokens/daily", "read-secret")).status, 422);
    assert.equal((await call("GET", "/tokens/daily?from=yesterday", "read-secret")).status, 422);
    assert.equal((await call("GET", "/tokens/daily?from=2026-13-01", "read-secret")).status, 422);
  });

  it("超過上限時留下最新的日子並標 truncated", async () => {
    const a = await addDevice("Mac");
    const insert = db.db.prepare("INSERT INTO daily_tokens (device_id, day, provider, model, updated_at) VALUES (?, ?, 'claude', ?, 0)");
    db.db.exec("BEGIN");
    for (let i = 0; i <= MAX_DOWNLOAD_ROWS; i++) insert.run(a.device_id, daysAgo(i % 30), `claude-m${Math.floor(i / 30)}`);
    db.db.exec("COMMIT");
    const data = (await download(daysAgo(30))) as { rows: Record<string, unknown>[]; truncated?: boolean };
    assert.equal(data.truncated, true);
    assert.equal(data.rows.length, MAX_DOWNLOAD_ROWS);
    assert.equal(data.rows.at(-1)?.day, today());
    assert.ok(data.rows.every((r, i) => i === 0 || String(r.day) >= String(data.rows[i - 1].day)));
    assert.equal((await download(today())).truncated, undefined);
  });

  it("其他方法回 405", async () => {
    assert.equal((await call("DELETE", "/tokens/daily", "read-secret")).status, 405);
  });
});
