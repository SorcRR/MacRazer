// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// Usage stats, from Macs whose owner said yes in the app. Mirrors `UsageStats` in
// Sources/MacRazer/UsageStats.swift.
//
//   POST   /v1/stats       a ping: this Mac's versions and the mice it has seen
//   DELETE /v1/stats/<id>  Delete My Data: the ID goes, the details stay without it
//
// Kept: one row per Mac and one per mouse it reported, dated to the day. Never kept: the IP
// address (the rate limits only see a salted hash of it that changes daily), anything about
// the request beyond the checked fields, and any log line with the ID in it.

import { readCapped, reply, positive } from "./http";
import { count, dayOf, ipKey, withinCap, type Database } from "./limits";
import { bool, fail, int, list, obj, oneOf, str, text, ValidationError } from "./validate";

export interface StatsEnv {
  DB: Database;
  /// `ratelimits` binding, for bursts. Its own, so pings can't use up the device reports'.
  STATS_BURST: { limit(options: { key: string }): Promise<{ success: boolean }> };
  IP_SALT?: string;
  /// New Macs accepted per day, per sender and in total. Pings from a Mac already known
  /// aren't counted here: only new rows grow the database.
  DAILY_NEW_PER_IP?: string;
  DAILY_NEW_TOTAL?: string;
  /// Pings accepted per day from everyone, known Macs included. Each costs a few D1 writes,
  /// and the device reports' counters need some of the same daily allowance, so stats stop
  /// for the day well before it runs out. Deletions are never capped.
  DAILY_STATS_TOTAL?: string;
}

export const STATS_PATH = "/v1/stats";
/// A ping is a few hundred bytes. Four mice with long names still fit well under this.
export const MAX_PING_BYTES = 4 * 1024;
/// More than any one Mac plausibly has, so a junk sender can't grow one row's mice forever.
export const MAX_MICE_PER_MAC = 16;
/// 16 bytes of SHA-256, in lowercase hex. `UsageStats.machineID` in the app.
export const ID = /^[0-9a-f]{32}$/;

export interface Mouse {
  pid: number;
  name: string;
  link: "wired" | "dongle" | "bluetooth" | "unknown";
  supported: boolean;
}

export interface Ping {
  v: 1;
  id: string;
  /// "first": the first ping since the app's preferences were empty. "update": the version
  /// changed. "mouse": a mouse this Mac hadn't reported yet.
  event: "first" | "update" | "mouse";
  app: string;
  os: string;
  arch: "arm64" | "x86_64";
  mice: Mouse[];
}

const mouse = obj({
  pid: int(0, 0xffff),
  // From the mouse, so cleaned rather than refused, like the device report's product names.
  name: text(64),
  link: oneOf("wired", "dongle", "bluetooth", "unknown"),
  supported: bool,
});

const ping = obj({
  v: int(1, 1),
  id: str(32, { pattern: ID }),
  event: oneOf("first", "update", "mouse"),
  app: str(32, { pattern: /^[0-9A-Za-z][0-9A-Za-z.+-]*$/ }),
  os: str(11, { pattern: /^\d{1,3}(\.\d{1,3}){0,2}$/ }),
  arch: oneOf("arm64", "x86_64"),
  mice: list(mouse, 4),
});

export function validatePing(value: unknown): Ping {
  const p = ping(value, "ping") as Ping;
  // text() cuts at 64 UTF-16 units, which can leave half of an emoji at the end.
  for (const m of p.mice) m.name = m.name.replace(/[\uD800-\uDBFF]$/, "").trim() || "Unknown mouse";
  if (new Set(p.mice.map((m) => `${m.pid}/${m.link}`)).size !== p.mice.length) fail("ping.mice", "duplicate mouse");
  return p;
}

export async function handleStats(request: Request, env: StatsEnv, now: Date): Promise<Response> {
  const rest = new URL(request.url).pathname.slice(STATS_PATH.length);
  let id: string | null = null;
  if (rest === "") {
    if (request.method !== "POST") return reply(405, "method_not_allowed", { Allow: "POST" });
  } else {
    id = rest.slice(1);
    if (!ID.test(id)) return reply(404, "not_found");
    if (request.method !== "DELETE") return reply(405, "method_not_allowed", { Allow: "DELETE" });
  }
  if (!env.IP_SALT) {
    console.error("misconfigured: IP_SALT is missing");
    return reply(503, "unavailable");
  }
  // The same daily hash as the reports, under its own prefix so the two never share a count.
  const sender = "stats:" + (await ipKey(request.headers.get("cf-connecting-ip") ?? "unknown", env.IP_SALT, dayOf(now)));
  if (!(await env.STATS_BURST.limit({ key: sender })).success) return reply(429, "slow_down");

  if (id !== null) {
    await forget(env.DB, id, now);
    return reply(200, "deleted");
  }

  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
    return reply(415, "not_json");
  }
  if (Number(request.headers.get("content-length") ?? 0) > MAX_PING_BYTES) return reply(413, "too_large");
  const body = await readCapped(request, MAX_PING_BYTES);
  if (body === null) return reply(413, "too_large");
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    return reply(400, "bad_json");
  }
  let p: Ping;
  try {
    p = validatePing(parsed);
  } catch (error) {
    if (error instanceof ValidationError) return reply(400, "invalid", {}, error.message);
    throw error;
  }

  const day = dayOf(now);
  // Checked before anything is counted, so a flood past it writes nothing.
  if (!(await withinCap(env.DB, day, "stats:total", positive(env.DAILY_STATS_TOTAL, 10000)))) {
    return reply(429, "daily_limit");
  }
  const known = await env.DB.prepare("SELECT 1 AS known FROM installs WHERE id = ?1").bind(p.id).first();
  if (!known) {
    const newTotal = positive(env.DAILY_NEW_TOTAL, 2000);
    if ((await count(env.DB, day, "new:total")) >= newTotal) return reply(429, "daily_limit");
    if (!(await withinCap(env.DB, day, `new:${sender}`, positive(env.DAILY_NEW_PER_IP, 20)))) return reply(429, "daily_limit");
    if (!(await withinCap(env.DB, day, "new:total", newTotal))) return reply(429, "daily_limit");
  }
  await record(env.DB, p, now);
  return reply(200, "recorded");
}

/// One ping into the tables. A Mac's versions are whatever it last said; its mice add up.
export async function record(db: Database, p: Ping, now: Date): Promise<void> {
  const day = dayOf(now);
  const statements = [
    db.prepare(
      "INSERT INTO installs (id, first_seen, last_seen, app, os, arch) VALUES (?1, ?2, ?2, ?3, ?4, ?5) " +
        "ON CONFLICT (id) DO UPDATE SET last_seen = ?2, app = ?3, os = ?4, arch = ?5, " +
        "reinstalls = reinstalls + ?6",
    ).bind(p.id, day, p.app, p.os, p.arch, p.event === "first" ? 1 : 0),
  ];
  for (const m of p.mice) {
    // A new mouse only while the Mac is under the cap; one it already has is always updated.
    statements.push(
      db.prepare(
        "INSERT INTO install_mice (id, pid, link, name, supported, first_seen, last_seen) " +
          "SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?6 " +
          "WHERE (SELECT COUNT(*) FROM install_mice WHERE id = ?1) < ?7 " +
          "OR EXISTS (SELECT 1 FROM install_mice WHERE id = ?1 AND pid = ?2 AND link = ?3) " +
          "ON CONFLICT (id, pid, link) DO UPDATE SET name = ?4, supported = ?5, last_seen = ?6",
      ).bind(p.id, m.pid, m.link, m.name, m.supported ? 1 : 0, day, MAX_MICE_PER_MAC),
    );
  }
  await db.batch(statements);
}

/// Delete My Data. The rows lose their ID and move to tables nothing links to a Mac: the
/// counts stay right, and the person is gone from them. Nothing happens for an unknown ID,
/// and the answer is the same either way, so the route can't be used to test IDs.
export async function forget(db: Database, id: string, now: Date): Promise<void> {
  const day = dayOf(now);
  await db.batch([
    db.prepare(
      "INSERT INTO deleted_installs (deleted_on, app, os, arch, days_used) " +
        "SELECT ?2, app, os, arch, MAX(0, CAST(julianday(?2) - julianday(first_seen) AS INTEGER)) " +
        "FROM installs WHERE id = ?1",
    ).bind(id, day),
    db.prepare(
      "INSERT INTO deleted_mice (deleted_month, pid, link, name, supported) " +
        "SELECT ?2, pid, link, name, supported FROM install_mice WHERE id = ?1",
    ).bind(id, day.slice(0, 7)),
    db.prepare("DELETE FROM install_mice WHERE id = ?1").bind(id),
    db.prepare("DELETE FROM installs WHERE id = ?1").bind(id),
  ]);
}
