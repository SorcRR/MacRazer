// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// Daily caps, counted in D1. The rate-limit binding only counts over 10 or 60 seconds, per
// Cloudflare location, so it handles bursts and this handles days. Only counters are kept:
// no report content, and no IP address, only a salted hash of one that changes every day.

/// The slice of D1's API this uses, so tests can run the same SQL on SQLite.
export interface Database {
  prepare(sql: string): Statement;
}
export interface Statement {
  bind(...values: unknown[]): Statement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  run(): Promise<unknown>;
}

const HIT =
  "INSERT INTO counters (day, key, count) VALUES (?1, ?2, 1) " +
  "ON CONFLICT (day, key) DO UPDATE SET count = count + 1 RETURNING count";

/// UTC, so every location agrees on when a day ends.
export function dayOf(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/// A key for one IP on one day. Salted with a secret, so the table can't be matched against
/// a list of addresses, and with the day, so the same IP can't be followed across days.
export async function ipKey(ip: string, salt: string, day: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}|${day}|${ip}`));
  return "ip:" + [...new Uint8Array(digest).slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hit(db: Database, day: string, key: string): Promise<number> {
  const row = await db.prepare(HIT).bind(day, key).first<{ count: number }>();
  return Number(row?.count ?? Infinity);
}

export interface Caps {
  perIp: number;
  total: number;
}

/// Counts one report and says whether it is within today's caps. The total is only counted
/// for an IP still within its own cap, so one sender going over can't use up everyone's day.
export async function admit(db: Database, ip: string, salt: string, now: Date, caps: Caps): Promise<boolean> {
  const day = dayOf(now);
  if ((await hit(db, day, await ipKey(ip, salt, day))) > caps.perIp) return false;
  return (await hit(db, day, "total")) <= caps.total;
}

/// Run daily by the cron trigger. Rows go once they're more than two days old; only today's
/// are ever read.
export async function cleanUp(db: Database, now: Date): Promise<void> {
  const cutoff = dayOf(new Date(now.getTime() - 2 * 86_400_000));
  await db.prepare("DELETE FROM counters WHERE day < ?1").bind(cutoff).run();
}
