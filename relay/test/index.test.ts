import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import worker, { MAX_BODY_BYTES, PAIRING, normalizeCode, readLimited, type Env } from "../src/index.ts";

class MemoryKV {
  store = new Map<string, string>();
  ttl = new Map<string, number | undefined>();
  async get(key: string) {
    return this.store.get(key) ?? null;
  }
  async put(key: string, value: string, options?: { expirationTtl?: number }) {
    this.store.set(key, value);
    this.ttl.set(key, options?.expirationTtl);
  }
  async delete(key: string) {
    this.store.delete(key);
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
    const credits = Array.from({ length: 16 }, () => ({ expires_at: "2026-11-20T05:00:00Z", count: 1000 }));
    const provider = {
      plan: "Max", error: null, windows: Array.from({ length: 16 }, (_, i) => window(i)),
      reset_credits: { available: 1000, credits },
    };
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

  it("保存重置次數卷的張數與到期時間，卷的其他欄位被移除", async () => {
    const resetCredits = { available: 3, credits: [{ expires_at: "2026-10-23T03:00:00Z", count: 2 }, { expires_at: null }] };
    const body = snapshot({
      reset_credits: { ...resetCredits, id: "leak", credits: [{ ...resetCredits.credits[0], id: "leak", title: "leak" }, {}] },
    });
    assert.equal((await post(body)).status, 204);
    assert.ok(!kv.store.get("latest")!.includes("leak"));
    assert.deepEqual((await (await call("GET", "read-secret")).json()).providers.claude.reset_credits, resetCredits);
  });

  it("預測與事故只保留白名單欄位，格式不符時丟掉欄位或項目、不擋下快照（ADR-0018）", async () => {
    const forecast = { exhausts_at: "2026-10-21T04:00:00Z", urgent: true, faster: 2.1, note: "leak" };
    const incidents = [
      { name: "Elevated errors", impact: "major", url: "https://status.claude.com/incidents/abc", started_at: "2026-10-21T02:00:00Z", body: "leak" },
      { name: "Bad link", impact: "minor", url: "https://evil.example/incidents/x", started_at: "yesterday" },
      { name: "", impact: "minor" },
      { name: "Bad impact", impact: "apocalyptic" },
      "x",
      { name: "Third", impact: "none" },
      { name: "Fourth", impact: "none" },
    ];
    assert.equal((await post(snapshot({ windows: [{ ...WINDOW, forecast }], incidents }))).status, 204);
    const saved = (await (await call("GET", "read-secret")).json()).providers.claude;
    assert.deepEqual(saved.windows[0].forecast, { exhausts_at: "2026-10-21T04:00:00Z", urgent: true, faster: 2.1 });
    assert.deepEqual(saved.incidents, [
      { name: "Elevated errors", impact: "major", url: "https://status.claude.com/incidents/abc", started_at: "2026-10-21T02:00:00Z" },
      { name: "Bad link", impact: "minor" },
      { name: "Third", impact: "none" },
    ]);
    for (const [bad, key] of [[{ urgent: true }, "forecast"], [{ exhausts_at: "2026-10-21T04:00:00Z", urgent: "yes" }, "forecast"]] as const) {
      assert.equal((await post(snapshot({ windows: [{ ...WINDOW, forecast: bad }], incidents: "down" }))).status, 204);
      const again = (await (await call("GET", "read-secret")).json()).providers.claude;
      assert.ok(!(key in again.windows[0]));
      assert.ok(!("incidents" in again));
    }
    // 倍數不合理時只丟倍數
    assert.equal((await post(snapshot({ windows: [{ ...WINDOW, forecast: { ...forecast, faster: -1 } }] }))).status, 204);
    assert.deepEqual((await (await call("GET", "read-secret")).json()).providers.claude.windows[0].forecast,
      { exhausts_at: "2026-10-21T04:00:00Z", urgent: true });
  });

  it("沒有明細的重置卷存成空陣列；沒有或 null 的 reset_credits 不保存", async () => {
    assert.equal((await post(snapshot({ reset_credits: { available: 2 } }))).status, 204);
    assert.deepEqual((await (await call("GET", "read-secret")).json()).providers.claude.reset_credits, { available: 2, credits: [] });
    assert.equal((await post(snapshot({ reset_credits: null }))).status, 204);
    assert.ok(!("reset_credits" in (await (await call("GET", "read-secret")).json()).providers.claude));
  });

  const invalid: [string, string][] = [
    ["providers 是陣列", JSON.stringify({ ...SNAPSHOT, providers: [] })],
    ["updated_at 不是日期", JSON.stringify({ ...SNAPSHOT, updated_at: "昨天" })],
    ["updated_at 不存在的日期", JSON.stringify({ ...SNAPSHOT, updated_at: "2026-13-45T00:00:00Z" })],
    ["updated_at 2 月 30 日（Date.parse 會進位到 3 月 2 日）", JSON.stringify({ ...SNAPSHOT, updated_at: "2026-02-30T00:00:00Z" })],
    ["updated_at 含小數秒（iOS 17 解不出來）", JSON.stringify({ ...SNAPSHOT, updated_at: "2026-10-21T03:00:00.5Z" })],
    ["resets_at 含小數秒", snapshot({ windows: [{ ...WINDOW, resets_at: "2026-10-21T05:00:00.123Z" }] })],
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
    ["reset_credits 不是物件", snapshot({ reset_credits: 2 })],
    ["重置卷張數缺少", snapshot({ reset_credits: { credits: [] } })],
    ["重置卷張數是小數", snapshot({ reset_credits: { available: 1.5 } })],
    ["重置卷張數是負數", snapshot({ reset_credits: { available: -1 } })],
    ["重置卷張數過多", snapshot({ reset_credits: { available: 1001 } })],
    ["重置卷明細不是陣列", snapshot({ reset_credits: { available: 1, credits: {} } })],
    ["重置卷明細不是物件", snapshot({ reset_credits: { available: 1, credits: ["x"] } })],
    ["重置卷到期時間不是日期", snapshot({ reset_credits: { available: 1, credits: [{ expires_at: "soon" }] } })],
    ["重置卷 count 是 0", snapshot({ reset_credits: { available: 1, credits: [{ expires_at: null, count: 0 }] } })],
    ["重置卷 count 是字串", snapshot({ reset_credits: { available: 1, credits: [{ expires_at: null, count: "1" }] } })],
    ["重置卷 count 過大", snapshot({ reset_credits: { available: 1, credits: [{ expires_at: null, count: 1001 }] } })],
    [
      "重置卷明細過多",
      snapshot({ reset_credits: { available: 17, credits: Array.from({ length: 17 }, () => ({ expires_at: null })) } }),
    ],
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

describe("iPhone 配對（ADR-0012）", () => {
  const pair = () => call("POST", "write-secret", "", "/pair");
  const claim = (code: unknown) => call("POST", undefined, JSON.stringify({ code }), "/pair/claim");

  it("寫入密鑰產生短碼，iPhone 以短碼換到讀取密鑰（只能用一次）", async () => {
    const res = await pair();
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("Cache-Control"), "no-store");
    const { code, expires_at } = await res.json();
    assert.match(code, /^[0-9A-HJKMNP-TV-Z]{8}$/);
    assert.match(expires_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const ttl = Date.parse(expires_at) - Date.now();
    assert.ok(ttl > 590_000 && ttl <= 600_000);
    // 只存雜湊，KV 裡看不到短碼本身
    assert.ok(!kv.store.get("pair")!.includes(code));
    assert.equal(kv.ttl.get("pair"), PAIRING.ttlSeconds);

    // 使用者輸入時的大小寫與連字號都可以
    const ok = await claim(`${code.slice(0, 4).toLowerCase()}-${code.slice(4)}`);
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { read_token: "read-secret" });
    assert.equal((await claim(code)).status, 403);
    assert.equal(kv.store.has("pair"), false);
  });

  it("讀取密鑰或沒有密鑰不能產生短碼", async () => {
    assert.equal((await call("POST", "read-secret", "", "/pair")).status, 401);
    assert.equal((await call("POST", undefined, "", "/pair")).status, 401);
    assert.equal(kv.store.size, 0);
  });

  it("再產生一組就取代舊的", async () => {
    const first = (await (await pair()).json()).code;
    const second = (await (await pair()).json()).code;
    if (first !== second) assert.equal((await claim(first)).status, 403);
    assert.equal((await claim(second)).status, 200);
  });

  it("錯誤、到期、沒有短碼、格式不對都回 403", async () => {
    assert.equal((await claim("7K3MQ9TD")).status, 403); // 還沒產生
    const { code } = await (await pair()).json();
    const record = JSON.parse(kv.store.get("pair")!);
    kv.store.set("pair", JSON.stringify({ ...record, expires_at: Date.now() - 1 }));
    assert.equal((await claim(code)).status, 403);
    assert.equal(kv.store.has("pair"), false);
    assert.equal((await call("POST", undefined, "{not json", "/pair/claim")).status, 403);
    assert.equal((await claim(12345678)).status, 403);
    assert.equal((await claim("short")).status, 403);
    const big = await call("POST", undefined, JSON.stringify({ code: "x".repeat(2000) }), "/pair/claim");
    assert.equal(big.status, 413);
  });

  it("錯 5 次就作廢，正確的短碼也不能再用", async () => {
    const { code } = await (await pair()).json();
    const wrong = code[0] === "0" ? `1${code.slice(1)}` : `0${code.slice(1)}`;
    for (let i = 1; i < PAIRING.maxFailures; i++) {
      assert.equal((await claim(wrong)).status, 403);
      const { hash } = JSON.parse(kv.store.get("pair")!);
      assert.equal(kv.store.get(`pair-fail:${hash.slice(0, 16)}`), String(i));
    }
    assert.equal((await claim(wrong)).status, 403);
    assert.equal(kv.store.has("pair"), false);
    assert.equal((await claim(code)).status, 403);
  });

  it("晚到的失敗寫入不會讓已兌換的短碼復活，也不影響新發的短碼（並行）", async () => {
    // 讓錯誤請求停在它的第一個寫入，先完成其他請求再放行
    const pauseNextPut = () => {
      const realPut = kv.put.bind(kv);
      let release!: () => void;
      let reached!: () => void;
      const gate = new Promise<void>((r) => (release = r));
      const arrived = new Promise<void>((r) => (reached = r));
      kv.put = async (key, value, options) => {
        kv.put = realPut;
        reached();
        await gate;
        return realPut(key, value, options);
      };
      return { arrived, release };
    };
    const wrongOf = (code: string) => (code[0] === "0" ? `1${code.slice(1)}` : `0${code.slice(1)}`);

    const { code } = await (await pair()).json();
    let gate = pauseNextPut();
    const late = claim(wrongOf(code));
    await gate.arrived;
    assert.equal((await claim(code)).status, 200);
    gate.release();
    assert.equal((await late).status, 403);
    assert.equal(kv.store.has("pair"), false);
    assert.equal((await claim(code)).status, 403);

    const { code: old } = await (await pair()).json();
    gate = pauseNextPut();
    const stale = claim(wrongOf(old));
    await gate.arrived;
    const { code: fresh } = await (await pair()).json();
    gate.release();
    assert.equal((await stale).status, 403);
    if (old !== fresh) assert.equal((await claim(old)).status, 403);
    assert.equal((await claim(fresh)).status, 200);
  });

  it("兌換內容超過上限時邊讀邊停，不讀完整份（沒有 Content-Length 的串流）", async () => {
    let pulled = 0;
    const chunk = new TextEncoder().encode("x".repeat(256));
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulled += chunk.byteLength;
        if (pulled > 20 * 1024) controller.close();
        else controller.enqueue(chunk);
      },
    });
    const req = new Request("https://relay.test/pair/claim", { method: "POST", body: stream, duplex: "half" } as RequestInit);
    assert.equal(req.headers.get("Content-Length"), null);
    assert.equal((await worker.fetch(req, env)).status, 413);
    assert.ok(pulled <= PAIRING.maxClaimBytes + 2 * chunk.byteLength, `讀了 ${pulled} bytes`);

    // 宣告的長度超過上限：不讀內容
    const declared = new Request("https://relay.test/pair/claim", {
      method: "POST",
      body: "{}",
      headers: { "Content-Length": String(PAIRING.maxClaimBytes + 1) },
    });
    assert.equal(await readLimited(declared, PAIRING.maxClaimBytes), null);

    // 多位元組字元以位元組計算；恰好在上限是合法的
    const zh = "中".repeat(PAIRING.maxClaimBytes / 4); // 3 bytes × 256 = 768
    assert.equal(await readLimited(new Request("https://x", { method: "POST", body: zh }), PAIRING.maxClaimBytes), zh);
    const exact = "a".repeat(PAIRING.maxClaimBytes);
    assert.equal(await readLimited(new Request("https://x", { method: "POST", body: exact }), PAIRING.maxClaimBytes), exact);
    const over = "中".repeat(342); // 1026 bytes
    assert.equal(await readLimited(new Request("https://x", { method: "POST", body: over }), PAIRING.maxClaimBytes), null);
  });

  it("格式不對的請求不讀寫 KV、不算錯誤次數（Fable F-01）", async () => {
    const { code } = await (await pair()).json();
    let reads = 0;
    let writes = 0;
    const get = kv.get.bind(kv);
    const put = kv.put.bind(kv);
    kv.get = async (key) => (reads++, get(key));
    kv.put = async (key, value, options) => (writes++, put(key, value, options));
    for (let i = 0; i < PAIRING.maxFailures + 2; i++) {
      assert.equal((await claim("short")).status, 403);
      assert.equal((await call("POST", undefined, "{not json", "/pair/claim")).status, 403);
    }
    assert.equal(reads, 0);
    assert.equal(writes, 0);
    assert.equal((await claim(code)).status, 200);
  });

  it("短碼的正規化與 iPhone 相同", () => {
    assert.equal(normalizeCode("7k3m-q9td"), "7K3MQ9TD");
    assert.equal(normalizeCode(" oil0 1234 "), "01101234");
    assert.equal(normalizeCode("7K3M-Q9TU"), null);
    assert.equal(normalizeCode("7K3M-Q9T"), null);
  });

  it("配對端點只接受 POST", async () => {
    const res = await call("GET", "write-secret", undefined, "/pair");
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("Allow"), "POST");
    assert.equal((await call("GET", undefined, undefined, "/pair/claim")).status, 405);
    assert.equal((await call("GET", undefined, undefined, "/pair/other")).status, 404);
  });
});
