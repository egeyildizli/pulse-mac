import { Database } from "bun:sqlite";

type Val = string | number | bigint | null | Uint8Array;
const norm = (v: unknown): Val => {
  if (v === undefined || v === null) return null;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "object" && !(v instanceof Uint8Array)) return JSON.stringify(v);
  return v as Val;
};

export class LocalStmt {
  constructor(private db: Database, private sql: string, private params: Val[] = []) {}
  bind(...p: unknown[]) {
    return new LocalStmt(this.db, this.sql, p.map(norm));
  }
  allSync<T = Record<string, unknown>>(): T[] {
    return this.db.query(this.sql).all(...this.params) as T[];
  }
  runSync() {
    const r = this.db.query(this.sql).run(...this.params);
    return { success: true, results: [], meta: { changes: r.changes, last_row_id: Number(r.lastInsertRowid) } };
  }
  async all<T = Record<string, unknown>>() {
    return { success: true, results: this.allSync<T>(), meta: {} };
  }
  async first<T = Record<string, unknown>>(col?: string): Promise<T | null> {
    const r = this.db.query(this.sql).get(...this.params) as Record<string, unknown> | null;
    if (!r) return null;
    return (col ? r[col] : r) as T;
  }
  async run() {
    return this.runSync();
  }
  async raw() {
    return this.db.query(this.sql).values(...this.params);
  }
}

export class LocalD1 {
  readonly db: Database;
  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.run("PRAGMA journal_mode = WAL");
    this.db.run("PRAGMA busy_timeout = 5000");
  }
  prepare(sql: string) {
    return new LocalStmt(this.db, sql);
  }
  async batch(stmts: LocalStmt[]) {
    return this.db.transaction(() => stmts.map((s) => s.runSync()))();
  }
  async exec(sql: string) {
    for (const part of sql.split(/;\s*\n/)) if (part.trim()) this.db.run(part);
    return { count: 0, duration: 0 };
  }
}
