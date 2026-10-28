import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { MAX_AGENT_BODY_BYTES } from "../src/agents.ts";
import { MAX_BODY_BYTES } from "../src/index.ts";
import { MAX_TOKENS_BODY_BYTES } from "../src/tokens.ts";

// README 的端點表寫的大小上限要等於程式裡的常數（曾經寫 16 KB、程式是 64 KB）
const README = readFileSync(new URL("../README.md", import.meta.url), "utf8");

function limitKB(path: string): number {
  const row = README.split("\n").find((line) => line.startsWith("| `POST` | `" + path + "` |"));
  assert.ok(row, `README 沒有 POST ${path}`);
  const match = row.match(/超過 (\d+) KB `413`/);
  assert.ok(match, `POST ${path} 沒有寫大小上限`);
  return Number(match[1]);
}

describe("README", () => {
  it("POST /usage 的大小上限與 MAX_BODY_BYTES 相同", () => {
    assert.equal(limitKB("/usage") * 1024, MAX_BODY_BYTES);
  });

  it("POST /tokens/daily 的大小上限與 MAX_TOKENS_BODY_BYTES 相同", () => {
    assert.equal(limitKB("/tokens/daily") * 1024, MAX_TOKENS_BODY_BYTES);
  });

  it("POST /agents/state 的大小上限與 MAX_AGENT_BODY_BYTES 相同", () => {
    assert.equal(limitKB("/agents/state") * 1024, MAX_AGENT_BODY_BYTES);
  });
});
