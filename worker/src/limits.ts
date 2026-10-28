// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// Daily caps, counted in D1. The rate-limit binding only counts over 10 or 60 seconds, per
// Cloudflare location, so it handles bursts and this handles days. Only counters are kept:
// no report content, and no IP address, only a salted hash of one that changes every day.

/// The slice of D1's API this uses, so tests can run the same SQL on SQLite.
export interface Database {
  prepare(sql: string): Statement;
  /// Runs the statements in one transaction: all of them or none.
  batch(statements: Statement[]): Promise<unknown>;
}
export interface Statement {
  bind(...values: unknown[]): Statement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
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

export async function hit(db: Database, day: string, key: string): Promise<number> {
  const row = await db.prepare(HIT).bind(day, key).first<{ count: number }>();
  return Number(row?.count ?? Infinity);
}

export interface Caps {
  perIp: number;
  total: number;
}

export interface Admission {
  allowed: boolean;
  day: string;
  /// What was counted, for `refund`.
  counted: string[];
}

/// Today's count for `key`, without counting anything.
export async function count(db: Database, day: string, key: string): Promise<number> {
  const row = await db.prepare("SELECT count FROM counters WHERE day = ?1 AND key = ?2").bind(day, key).first<{ count: number }>();
  return Number(row?.count ?? 0);
}

/// Counts one more for `key` if today's count is still under `cap`, and says whether it was.
/// Read first, so a request over the cap costs a read and no write: a flood past the cap
/// can't use up D1's daily writes, which every route here shares.
export async function withinCap(db: Database, day: string, key: string, cap: number): Promise<boolean> {
  if ((await count(db, day, key)) >= cap) return false;
  return (await hit(db, day, key)) <= cap;
}

/// Counts one report from `sender` (an `ipKey`) and says whether it is within today's caps.
/// The total is only counted for a sender still within its own cap, so one sender going
/// over can't use up everyone's day. Nothing is written for a report already over a cap.
export async function admit(db: Database, sender: string, now: Date, caps: Caps): Promise<Admission> {
  const day = dayOf(now);
  // The day's total first, read only: once it's spent, a flood from new addresses writes
  // nothing either.
  if ((await count(db, day, "total")) >= caps.total) return { allowed: false, day, counted: [] };
  if (!(await withinCap(db, day, sender, caps.perIp))) return { allowed: false, day, counted: [] };
  const allowed = await withinCap(db, day, "total", caps.total);
  return { allowed, day, counted: allowed ? [sender, "total"] : [sender] };
}

/// Takes back an admitted report that wasn't sent after all, so a failure (a setup mistake,
/// or the email service's own limits) doesn't spend anyone's allowance.
export async function refund(db: Database, admission: Admission): Promise<void> {
  for (const key of admission.counted) {
    await db.prepare("UPDATE counters SET count = count - 1 WHERE day = ?1 AND key = ?2 AND count > 0")
      .bind(admission.day, key).run();
  }
}

/// Run daily by the cron trigger. Rows go once they're more than two days old; only today's
/// are ever read.
export async function cleanUp(db: Database, now: Date): Promise<void> {
  const cutoff = dayOf(new Date(now.getTime() - 2 * 86_400_000));
  await db.prepare("DELETE FROM counters WHERE day < ?1").bind(cutoff).run();
}
