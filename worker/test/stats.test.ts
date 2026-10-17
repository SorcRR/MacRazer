// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { handle, type Env } from "../src/handler";
import { MAX_MICE_PER_MAC, STATS_PATH, validatePing } from "../src/stats";
import { ValidationError } from "../src/validate";
// @ts-expect-error: a plain .mjs script.
import { format, QUERIES } from "../scripts/stats.mjs";
import { sqlite } from "./sqlite";

const NOW = new Date("2026-10-17T12:00:00Z");
const ID = "3f9a0c71e2b84d6a9c15e0b7d4a2f816";
/// Written by the app's own tests (UsageStatsTests), so a change to the app's ping shows up here.
const appPing = () => JSON.parse(readFileSync(new URL("./fixtures/usage-ping.json", import.meta.url), "utf8"));

const ping = (over: Record<string, unknown> = {}) => ({
  v: 1,
  id: ID,
  event: "first",
  app: "0.6.0",
  os: "26.1",
  arch: "arm64",
  mice: [{ pid: 0x00b0, name: "Razer Cobra Pro (Wireless)", link: "dongle", supported: true }],
  ...over,
});

function setup(overrides: Partial<Env> = {}, burstAllows = true) {
  const db = sqlite();
  const burstKeys: string[] = [];
  const env: Env = {
    EMAIL: { send: async () => { throw new Error("stats never email"); } },
    BURST: { limit: async () => { throw new Error("stats have their own limiter"); } },
    STATS_BURST: {
      limit: async ({ key }) => {
        burstKeys.push(key);
        return { success: burstAllows };
      },
    },
    DB: db,
    SENDER_ADDRESS: "reports@example.org",
    DESTINATION_ADDRESS: "maintainer@example.org",
    IP_SALT: "test-salt",
    ...overrides,
  };
  return { env, db, burstKeys };
}

function request(method: string, init: { body?: unknown; path?: string; ip?: string; type?: string } = {}) {
  return new Request(`https://macrazer-reports.example.workers.dev${init.path ?? STATS_PATH}`, {
    method,
    headers: { "content-type": init.type ?? "application/json", "cf-connecting-ip": init.ip ?? "203.0.113.7" },
    body: init.body === undefined ? undefined : typeof init.body === "string" ? init.body : JSON.stringify(init.body),
  });
}

async function send(env: Env, req: Request, now = NOW) {
  const response = await handle(req, env, now);
  return { status: response.status, body: (await response.json()) as { ok: boolean; error?: string; detail?: string } };
}

const post = (env: Env, body: unknown, now = NOW, ip?: string) => send(env, request("POST", { body, ip }), now);
const del = (env: Env, id = ID, now = NOW) => send(env, request("DELETE", { path: `${STATS_PATH}/${id}` }), now);

describe("the app's ping", () => {
  it("passes the schema as it is", () => {
    expect(validatePing(appPing())).toEqual(appPing());
  });
});

describe("a ping", () => {
  it("records the Mac and its mouse, dated to the day", async () => {
    const { env, db } = setup();
    expect((await post(env, ping())).status).toBe(200);
    expect(db.rows("installs")).toEqual([
      { id: ID, first_seen: "2026-10-17", last_seen: "2026-10-17", app: "0.6.0", os: "26.1", arch: "arm64", reinstalls: 0 },
    ]);
    expect(db.rows("install_mice")).toEqual([
      { id: ID, pid: 0xb0, link: "dongle", name: "Razer Cobra Pro (Wireless)", supported: 1, first_seen: "2026-10-17", last_seen: "2026-10-17" },
    ]);
  });

  it("keeps the first day, and updates the versions to the latest", async () => {
    const { env, db } = setup();
    await post(env, ping());
    await post(env, ping({ event: "update", app: "0.7.0", os: "26.2", mice: [] }), new Date("2026-11-02T08:00:00Z"));
    const [row] = db.rows("installs");
    expect(row).toMatchObject({ first_seen: "2026-10-17", last_seen: "2026-11-02", app: "0.7.0", os: "26.2", reinstalls: 0 });
    expect(db.rows("install_mice"), "a ping without mice leaves the old ones").toHaveLength(1);
  });

  it("counts a first ping from a Mac it already knows as a reinstall", async () => {
    const { env, db } = setup();
    await post(env, ping());
    await post(env, ping());
    expect(db.rows("installs")[0].reinstalls).toBe(1);
  });

  it("adds new mice and updates known ones", async () => {
    const { env, db } = setup();
    await post(env, ping());
    await post(env, ping({
      event: "mouse",
      mice: [
        { pid: 0x00b0, name: "Razer Cobra Pro (Wireless)", link: "dongle", supported: true },
        { pid: 0x00b0, name: "Razer Cobra Pro", link: "bluetooth", supported: false },
      ],
    }));
    expect(db.rows("install_mice").map((m) => `${m.pid}/${m.link}`)).toEqual(["176/dongle", "176/bluetooth"]);
  });

  it(`stops adding mice to one Mac at ${MAX_MICE_PER_MAC}, but still updates the ones it has`, async () => {
    const { env, db } = setup();
    for (let i = 0; i < MAX_MICE_PER_MAC + 4; i += 4) {
      const mice = [0, 1, 2, 3].map((j) => ({ pid: i + j, name: `Mouse ${i + j}`, link: "wired", supported: false }));
      await post(env, ping({ event: "mouse", mice }));
    }
    expect(db.rows("install_mice")).toHaveLength(MAX_MICE_PER_MAC);
    await post(env, ping({ event: "mouse", mice: [{ pid: 0, name: "Renamed", link: "wired", supported: true }] }));
    expect(db.rows("install_mice")[0]).toMatchObject({ name: "Renamed", supported: 1 });
  });

  it("cleans a mouse's name rather than refusing it", async () => {
    const { env, db } = setup();
    await post(env, ping({ mice: [{ pid: 1, name: "Razer\u0000 Thing\n", link: "unknown", supported: false }] }));
    await post(env, ping({ id: "0".repeat(32), mice: [{ pid: 2, name: " \u0007 ", link: "unknown", supported: false }] }));
    expect(db.rows("install_mice").map((m) => m.name)).toEqual(["Razer Thing", "Unknown mouse"]);
  });

  it("refuses anything that isn't exactly a ping", async () => {
    const { env, db } = setup();
    const bad: unknown[] = [
      ping({ v: 2 }),
      ping({ id: ID.toUpperCase() }),
      ping({ id: "abc" }),
      ping({ event: "launch" }),
      ping({ arch: "ppc" }),
      ping({ os: "26.1; DROP TABLE installs" }),
      ping({ app: "" }),
      ping({ extra: true }),
      ping({ mice: Array.from({ length: 5 }, (_, i) => ({ pid: i, name: "x", link: "wired", supported: true })) }),
      ping({ mice: [{ pid: 1, name: "a", link: "wired", supported: true }, { pid: 1, name: "b", link: "wired", supported: true }] }),
      ping({ mice: [{ pid: 0x10000, name: "x", link: "wired", supported: true }] }),
      ping({ mice: [{ pid: 1, name: "x", link: "wired", supported: "yes" }] }),
      "not json",
      [],
    ];
    for (const body of bad) expect((await post(env, body)).status, JSON.stringify(body)).toBe(400);
    expect(db.rows("installs")).toHaveLength(0);
    expect(() => validatePing(ping({ v: 2 }))).toThrow(ValidationError);
  });

  it("refuses the wrong method, type or size", async () => {
    const { env } = setup();
    expect((await send(env, request("GET"))).status).toBe(405);
    expect((await send(env, request("POST", { body: ping(), type: "text/plain" }))).status).toBe(415);
    expect((await send(env, request("POST", { body: ping({ pad: "x".repeat(5000) }) }))).status).toBe(413);
  });

  it("caps new Macs per sender and in total, but never a Mac it already knows", async () => {
    const { env, db } = setup({ DAILY_NEW_PER_IP: "2", DAILY_NEW_TOTAL: "3" });
    const id = (n: number) => n.toString(16).padStart(32, "0");
    expect((await post(env, ping({ id: id(1) }))).status).toBe(200);
    expect((await post(env, ping({ id: id(2) }))).status).toBe(200);
    expect((await post(env, ping({ id: id(3) }))).status).toBe(429);
    expect((await post(env, ping({ id: id(1), event: "update" }))).status, "known Mac").toBe(200);
    expect((await post(env, ping({ id: id(4) }), NOW, "198.51.100.1")).status).toBe(200);
    expect((await post(env, ping({ id: id(5) }), NOW, "198.51.100.2")).status, "total").toBe(429);
    expect(db.rows("installs")).toHaveLength(3);
  });

  it("is turned away in a burst before anything is read", async () => {
    const { env, db } = setup({}, false);
    expect((await post(env, ping())).status).toBe(429);
    expect(db.rows("installs")).toHaveLength(0);
  });

  it("never stores or limits by the IP address itself", async () => {
    const { env, db, burstKeys } = setup();
    await post(env, ping());
    const stored = JSON.stringify([db.rows(), db.rows("installs"), db.rows("install_mice"), burstKeys]);
    expect(stored).not.toContain("203.0.113.7");
    expect(burstKeys[0]).toMatch(/^stats:ip:[0-9a-f]{32}$/);
  });

  it("is unavailable without the salt", async () => {
    const { env, db } = setup({ IP_SALT: undefined });
    expect((await post(env, ping())).status).toBe(503);
    expect(db.rows("installs")).toHaveLength(0);
  });
});

describe("Delete My Data", () => {
  it("removes the ID and keeps the details without it", async () => {
    const { env, db } = setup();
    await post(env, ping());
    await post(env, ping({ id: "1".repeat(32) }));
    expect((await del(env, ID, new Date("2026-10-29T09:00:00Z"))).status).toBe(200);

    expect(db.rows("installs").map((r) => r.id)).toEqual(["1".repeat(32)]);
    expect(db.rows("install_mice").map((r) => r.id)).toEqual(["1".repeat(32)]);
    expect(db.rows("deleted_installs")).toEqual([
      { deleted_on: "2026-10-29", app: "0.6.0", os: "26.1", arch: "arm64", days_used: 12 },
    ]);
    expect(db.rows("deleted_mice")).toEqual([
      { deleted_on: "2026-10-29", pid: 0xb0, link: "dongle", name: "Razer Cobra Pro (Wireless)", supported: 1 },
    ]);
    expect(JSON.stringify([db.rows("deleted_installs"), db.rows("deleted_mice")])).not.toContain(ID);
  });

  it("answers the same for an ID it doesn't know, and records nothing", async () => {
    const { env, db } = setup();
    expect(await del(env)).toEqual({ status: 200, body: { ok: true } });
    expect(db.rows("deleted_installs")).toHaveLength(0);
    expect((await del(env)).status, "twice is fine").toBe(200);
  });

  it("lets the Mac opt in again as a new one", async () => {
    const { env, db } = setup();
    await post(env, ping());
    await del(env);
    await post(env, ping(), new Date("2026-12-01T00:00:00Z"));
    expect(db.rows("installs")[0]).toMatchObject({ first_seen: "2026-12-01", reinstalls: 0 });
  });

  it("takes only a well-formed ID and the DELETE method", async () => {
    const { env } = setup();
    expect((await del(env, "nope")).status).toBe(404);
    expect((await del(env, ID + "/x")).status).toBe(404);
    expect((await send(env, request("POST", { path: `${STATS_PATH}/${ID}`, body: ping() }))).status).toBe(405);
  });

  it("is limited like a ping", async () => {
    const { env, db } = setup({}, false);
    await db.batch([db.prepare("INSERT INTO installs (id, first_seen, last_seen, app, os, arch) VALUES (?1, '2026-10-01', '2026-10-01', '0.6.0', '26.1', 'arm64')").bind(ID)]);
    expect((await del(env)).status).toBe(429);
    expect(db.rows("installs")).toHaveLength(1);
  });
});

describe("npm run stats", () => {
  async function results(db: ReturnType<typeof sqlite>) {
    return Object.fromEntries(Object.entries(QUERIES as Record<string, string>).map(([k, sql]) => [k, db.all(sql)]));
  }

  it("runs every query on the real tables, empty or not", async () => {
    const { env, db } = setup();
    expect(format(await results(db))).toContain("Macs sharing            0");
    const today = new Date();
    await post(env, ping(), today);
    await post(env, ping({ id: "1".repeat(32), arch: "x86_64", os: "15.7.1", mice: [{ pid: 0x00b6, name: "Razer DeathAdder V3 Pro", link: "wired", supported: false }] }), today);
    await del(env, "1".repeat(32), today);
    await post(env, ping({ id: "2".repeat(32), app: "0.5.0" }), today);
    const out = format(await results(db));
    expect(out).toContain("Macs sharing            2");
    expect(out).toMatch(/Razer Cobra Pro \(Wireless\)\s+0x00B0\s+2\.4 GHz\s+2\s+yes/);
    expect(out).toMatch(/26\.x\s+2/);
    expect(out).toContain("Deleted their data  1 in all, 1 in the last 30 days");
    expect(out).toContain("Razer DeathAdder V3 Pro");
  });
});
