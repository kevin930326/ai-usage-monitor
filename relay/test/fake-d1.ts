// 測試用的 D1：Node 內建的 SQLite 套用真的 migration（migrations/*.sql），SQL 與正式環境相同。
// 只實作 Worker 用到的 prepare／bind／first／all／run／batch；batch 與 D1 一樣在同一個交易中執行。
import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";

import type { D1Database, D1PreparedStatement, D1Result } from "../src/tokens.ts";

const MIGRATIONS = new URL("../migrations/", import.meta.url);

class Statement implements D1PreparedStatement {
  private db: DatabaseSync;
  private sql: string;
  private values: SQLInputValue[];

  constructor(db: DatabaseSync, sql: string, values: SQLInputValue[] = []) {
    this.db = db;
    this.sql = sql;
    this.values = values;
  }

  bind(...values: unknown[]): D1PreparedStatement {
    return new Statement(this.db, this.sql, values as SQLInputValue[]);
  }

  async first<T>(): Promise<T | null> {
    return (this.db.prepare(this.sql).get(...this.values) as T | undefined) ?? null;
  }

  async all<T>(): Promise<D1Result<T>> {
    return { results: this.db.prepare(this.sql).all(...this.values) as T[] };
  }

  async run(): Promise<unknown> {
    return this.runSync();
  }

  runSync(): unknown {
    return this.db.prepare(this.sql).run(...this.values);
  }
}

export class FakeD1 implements D1Database {
  db = new DatabaseSync(":memory:");
  /** batch 被呼叫的次數（確認一次上傳只有一個交易） */
  batches = 0;

  constructor() {
    this.db.exec("PRAGMA foreign_keys = ON"); // D1 預設開啟外鍵檢查
    for (const file of readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
      this.db.exec(readFileSync(new URL(file, MIGRATIONS), "utf8"));
    }
  }

  prepare(sql: string): D1PreparedStatement {
    return new Statement(this.db, sql);
  }

  async batch(statements: D1PreparedStatement[]): Promise<unknown[]> {
    this.batches++;
    this.db.exec("BEGIN");
    try {
      const results = statements.map((s) => (s as Statement).runSync());
      this.db.exec("COMMIT");
      return results;
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    }
  }

  /** 整個資料庫的內容（確認沒有存下明文密鑰） */
  dump(): string {
    const tables = this.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[];
    return JSON.stringify(tables.map(({ name }) => this.db.prepare(`SELECT * FROM ${name}`).all()));
  }

  rows(): Record<string, unknown>[] {
    return this.db.prepare("SELECT * FROM daily_tokens ORDER BY device_id, day, provider, model").all() as Record<string, unknown>[];
  }
}
