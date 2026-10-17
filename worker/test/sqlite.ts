// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import type { Database, Statement } from "../src/limits";

const migrations = new URL("../migrations/", import.meta.url);

type Bound = Statement & { exec(): unknown };

/// D1's API over an in-memory SQLite, running every real migration in order and the real SQL.
/// `batch` is all or nothing, like D1's.
export function sqlite(): Database & {
  rows(table?: string): Record<string, unknown>[];
  all(sql: string): Record<string, unknown>[];
} {
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(migrations).filter((n) => n.endsWith(".sql")).sort()) {
    db.exec(readFileSync(new URL(name, migrations), "utf8"));
  }
  return {
    prepare(sql: string) {
      let args: unknown[] = [];
      const statement: Bound = {
        bind(...values: unknown[]) {
          args = values;
          return statement;
        },
        async first<T>() {
          return (db.prepare(sql).get(...(args as never[])) ?? null) as T | null;
        },
        async all<T>() {
          return { results: db.prepare(sql).all(...(args as never[])) as T[] };
        },
        async run() {
          return statement.exec();
        },
        exec() {
          return db.prepare(sql).run(...(args as never[]));
        },
      };
      return statement;
    },
    async batch(statements: Statement[]) {
      db.exec("BEGIN");
      try {
        const out = statements.map((s) => (s as Bound).exec());
        db.exec("COMMIT");
        return out;
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
    },
    rows: (table = "counters") => db.prepare(`SELECT * FROM ${table} ORDER BY ${table === "counters" ? "key" : "rowid"}`).all() as Record<string, unknown>[],
    all: (sql: string) => db.prepare(sql).all() as Record<string, unknown>[],
  };
}
