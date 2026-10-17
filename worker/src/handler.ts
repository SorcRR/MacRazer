// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// Routes a request: usage stats go to stats.ts, and a device report is checked here and
// emailed. Kept apart from index.ts because the Workers runtime treats every named export of
// the main module as an entry point, and refuses to start on a constant.

import { emailFor, type OutgoingEmail } from "./email";
import { admit, dayOf, ipKey, refund, type Database } from "./limits";
import { positive, readCapped, reply } from "./http";
import { handleStats, STATS_PATH, type StatsEnv } from "./stats";
import { validateReport, ValidationError } from "./validate";

export { reply };

export interface Env extends StatsEnv {
  /// `send_email` binding. Its `destination_address` is the only address it can send to.
  EMAIL: { send(message: OutgoingEmail): Promise<unknown> };
  /// `ratelimits` binding, for bursts.
  BURST: { limit(options: { key: string }): Promise<{ success: boolean }> };
  DB: Database;
  /// On a domain with Email Routing enabled.
  SENDER_ADDRESS: string;
  /// The binding's `destination_address`, again: `send()` needs a `to`.
  DESTINATION_ADDRESS: string;
  /// Secret (`wrangler secret put IP_SALT`). Without it the Worker refuses to run.
  IP_SALT?: string;
  DAILY_PER_IP?: string;
  DAILY_TOTAL?: string;
}

export const PATH = "/v1/device-report";
/// `DeviceReportOutput.maxReportBytes` in the app, which fits every report under it.
export const MAX_BYTES = 16 * 1024;


/// The app maps each status to a message: 200 sent, 400 refused, 413 too big, 429 try
/// later, anything else unavailable.
export async function handle(request: Request, env: Env, now: Date): Promise<Response> {
  const path = new URL(request.url).pathname;
  if (path === STATS_PATH || path.startsWith(`${STATS_PATH}/`)) return handleStats(request, env, now);
  if (path !== PATH) return reply(404, "not_found");
  if (request.method !== "POST") return reply(405, "method_not_allowed", { Allow: "POST" });
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) {
    return reply(415, "not_json");
  }
  // The declared size first, so an honest oversized request isn't even read. The bytes are
  // counted again as they arrive, since the header can lie or be missing.
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BYTES) return reply(413, "too_large");
  if (!env.IP_SALT || !env.SENDER_ADDRESS || !env.DESTINATION_ADDRESS) {
    console.error("misconfigured: IP_SALT, SENDER_ADDRESS or DESTINATION_ADDRESS is missing");
    return reply(503, "unavailable");
  }

  // The sender is only ever known by a salted hash of the IP, the burst limiter included.
  const sender = await ipKey(request.headers.get("cf-connecting-ip") ?? "unknown", env.IP_SALT, dayOf(now));
  if (!(await env.BURST.limit({ key: sender })).success) return reply(429, "slow_down");

  const body = await readCapped(request, MAX_BYTES);
  if (body === null) return reply(413, "too_large");
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    return reply(400, "bad_json");
  }
  let report;
  try {
    report = validateReport(parsed);
  } catch (error) {
    if (error instanceof ValidationError) return reply(400, "invalid", {}, error.message);
    throw error;
  }

  // Counted only for a valid report, so junk can't use up the day's allowance; the burst
  // limit above is what holds junk back.
  const caps = { perIp: positive(env.DAILY_PER_IP, 10), total: positive(env.DAILY_TOTAL, 200) };
  const admission = await admit(env.DB, sender, now, caps);
  if (!admission.allowed) return reply(429, "daily_limit");

  try {
    await env.EMAIL.send(emailFor(report, env.DESTINATION_ADDRESS, env.SENDER_ADDRESS));
  } catch (error) {
    // The error's code (E_SENDER_NOT_VERIFIED and so on) is what setup problems show up as.
    console.error("send failed", (error as { code?: string }).code ?? String(error));
    await refund(env.DB, admission);
    return reply(503, "unavailable");
  }
  console.log("sent", report.device.productID);
  return reply(200, "sent");
}
