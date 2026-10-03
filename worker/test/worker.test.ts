// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";
import * as main from "../src/index";
import { handle, MAX_BYTES, PATH, type Env } from "../src/handler";
import { verdictOf, type OutgoingEmail } from "../src/email";
import { validateReport } from "../src/validate";
import { cleanUp, dayOf, ipKey, type Database } from "../src/limits";

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
/// A real report: `devicetest` on a Cobra HyperSpeed over the dongle.
const cobra = () => JSON.parse(fixture("cobra-hyperspeed.json"));
const NOW = new Date("2026-10-03T12:00:00Z");

/// D1's API over an in-memory SQLite, running the real migration and the real SQL.
function sqlite(): Database & { rows(): Record<string, unknown>[] } {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../migrations/0001_counters.sql", import.meta.url), "utf8"));
  return {
    prepare(sql: string) {
      let args: unknown[] = [];
      const statement = {
        bind(...values: unknown[]) {
          args = values;
          return statement;
        },
        async first<T>() {
          return (db.prepare(sql).get(...(args as never[])) ?? null) as T | null;
        },
        async run() {
          return db.prepare(sql).run(...(args as never[]));
        },
      };
      return statement;
    },
    rows: () => db.prepare("SELECT * FROM counters ORDER BY key").all() as Record<string, unknown>[],
  };
}

function setup(overrides: Partial<Env> = {}, burstAllows = true) {
  const sent: OutgoingEmail[] = [];
  const burstKeys: string[] = [];
  const db = sqlite();
  const env: Env = {
    EMAIL: { send: async (m) => void sent.push(m) },
    BURST: {
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
  return { env, sent, db, burstKeys };
}

function post(body: unknown, init: { ip?: string; headers?: Record<string, string>; path?: string } = {}): Request {
  return new Request(`https://macrazer-reports.example.workers.dev${init.path ?? PATH}`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": init.ip ?? "203.0.113.7", ...init.headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function status(env: Env, request: Request) {
  const response = await handle(request, env, NOW);
  return { status: response.status, body: (await response.json()) as { ok: boolean; error?: string; detail?: string } };
}

describe("wrangler.toml", () => {
  it("sends to the address the binding is locked to", () => {
    const toml = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
    const locked = toml.match(/^destination_address = "([^"]+)"$/m)?.[1];
    const to = toml.match(/^DESTINATION_ADDRESS = "([^"]+)"$/m)?.[1];
    expect(locked).toBeTruthy();
    expect(to, "change both lines together").toBe(locked);
  });
});

describe("the main module", () => {
  it("exports nothing but the handler: the runtime won't start on a named export", () => {
    expect(Object.keys(main)).toEqual(["default"]);
  });
});

describe("the app's reports", () => {
  // full-report.json is written by the app's own tests (DeviceReportSenderTests) with every
  // field set. If the app's report changes, that file changes, and these fail until
  // src/validate.ts matches it.
  for (const name of ["full-report.json", "cobra-hyperspeed.json"]) {
    it(`pass the schema as they are: ${name}`, () => {
      const report = JSON.parse(fixture(name));
      expect(validateReport(report)).toEqual(report);
    });

    it(`get the verdict the app gave them: ${name}`, () => {
      const report = JSON.parse(fixture(name));
      expect(verdictOf(validateReport(report))).toEqual(report.verdict);
    });
  }

  it("carry every optional field in the full fixture", () => {
    const full = JSON.parse(fixture("full-report.json"));
    for (const key of ["registry", "verdict", "comment", "credit", "replyEmail", "exchangesDropped"]) {
      expect(full, key).toHaveProperty(key);
    }
    expect(full.device).toHaveProperty("connection");
    expect(full.device).toHaveProperty("controlInterface");
    expect(full.identify.data).toHaveProperty("dpiAttempts");
    expect(full.dpi.data).toHaveProperty("maxProbe");
    expect(full.lighting.data).toHaveProperty("turnedRed");
  });
});

describe("a report that passes", () => {
  it("is emailed once, from the sender, with the binding choosing the recipient", async () => {
    const { env, sent } = setup();
    expect((await status(env, post(cobra()))).status).toBe(200);
    expect(sent).toHaveLength(1);
    const [email] = sent;
    expect(email.from).toBe("reports@example.org");
    expect(email.to).toBe("maintainer@example.org");
    expect(email).not.toHaveProperty("replyTo");
    expect(email.subject).toBe("[MacRazer] Partly tested: Razer Cobra HyperSpeed (0x00DB)");
    expect(email.text).toContain("Razer Cobra HyperSpeed, product ID 0x00DB, firmware v1.0");
    expect(email.text).toContain("Passed: Identify, Battery, DPI, Polling rate");
    expect(email.text).toContain('"standardId": 31');
  });

  it("is replied to at the address the person gave", async () => {
    const { env, sent } = setup();
    await status(env, post({ ...cobra(), replyEmail: "person@example.com", comment: "Works great\non my Mac" }));
    expect(sent[0].replyTo).toBe("person@example.com");
    expect(sent[0].text).toContain("Comment:\nWorks great\non my Mac");
  });

  it("gets its subject from the outcomes, not from the verdict it claims", async () => {
    const { env, sent } = setup();
    const r = cobra();
    r.lighting.outcome = "failed";
    r.verdict.kind = "confirmed";
    await status(env, post(r));
    expect(sent[0].subject).toBe("[MacRazer] Possible regression: Razer Cobra HyperSpeed (0x00DB)");
  });

  it("names an unknown mouse's score", async () => {
    const { env, sent } = setup();
    const r = cobra();
    delete r.registry;
    r.dpi.outcome = "failed";
    r.lighting.outcome = "notSupported";
    await status(env, post(r));
    expect(sent[0].subject).toBe("[MacRazer] New mouse: 3 of 4 passed: Razer Cobra HyperSpeed (0x00DB)");
  });
});

describe("requests that are refused before reading", () => {
  it("on the wrong path, method or type", async () => {
    const { env, sent } = setup();
    expect((await status(env, post(cobra(), { path: "/" }))).status).toBe(404);
    expect((await status(env, new Request(`https://x.example${PATH}`))).status).toBe(405);
    expect((await status(env, post(cobra(), { headers: { "content-type": "text/plain" } }))).status).toBe(415);
    expect(sent).toHaveLength(0);
  });

  it("when the declared size is over the cap", async () => {
    const { env } = setup();
    expect((await status(env, post(cobra(), { headers: { "content-length": String(MAX_BYTES + 1) } }))).status).toBe(413);
  });

  it("when the bytes run over the cap, whatever the header says", async () => {
    const { env, sent } = setup();
    const big = new TextEncoder().encode(JSON.stringify({ ...cobra(), comment: "x".repeat(MAX_BYTES) }));
    const stream = new ReadableStream({
      start(c) {
        for (let i = 0; i < big.length; i += 1000) c.enqueue(big.slice(i, i + 1000));
        c.close();
      },
    });
    const request = new Request(`https://x.example${PATH}`, {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": "100" },
      body: stream,
      duplex: "half",
    } as RequestInit);
    expect((await status(env, request)).status).toBe(413);
    expect(sent).toHaveLength(0);
  });

  it("in a burst", async () => {
    const { env, sent, db } = setup({}, false);
    expect((await status(env, post(cobra()))).status).toBe(429);
    expect(sent).toHaveLength(0);
    expect(db.rows()).toHaveLength(0);
  });

  it("when the Worker is missing its salt", async () => {
    const { env, sent } = setup({ IP_SALT: undefined });
    expect((await status(env, post(cobra()))).status).toBe(503);
    expect(sent).toHaveLength(0);
  });
});

describe("reports that are refused", () => {
  const cases: [string, (r: Record<string, any>) => void, string][] = [
    ["an unknown field", (r) => (r.extra = 1), "report.extra"],
    ["an unknown nested field", (r) => (r.dpi.data.secret = "x"), "report.dpi.data.secret"],
    ["another vendor", (r) => (r.device.vendorID = 0x046d), "report.device.vendorID"],
    ["a header injected through the email", (r) => (r.replyEmail = "a@b.co\r\nBcc: x@y.z"), "report.replyEmail"],
    ["an email that isn't one", (r) => (r.replyEmail = "not-an-address"), "report.replyEmail"],
    ["a comment over the cap", (r) => (r.comment = "x".repeat(8001)), "report.comment"],
    ["too many exchanges", (r) => {
      // The smallest exchange there is, and none elsewhere, so the count trips before the size.
      for (const step of ["identify", "battery", "polling", "lighting"]) r[step].exchanges = [];
      r.dpi.exchanges = Array(151).fill({ commandClass: 4, commandId: 5, response: [], milliseconds: 1 });
    }, "report.dpi.exchanges"],
    ["a byte out of range", (r) => (r.dpi.exchanges[0].status = 256), "report.dpi.exchanges[0].status"],
    ["a made-up outcome", (r) => (r.battery.outcome = "great"), "report.battery.outcome"],
    ["a control interface past the list", (r) => (r.device.controlInterface = 9), "report.device.controlInterface"],
    ["a missing step", (r) => delete r.polling, "report.polling"],
    ["a schema from the future", (r) => (r.schemaVersion = 2), "report.schemaVersion"],
    ["a list where an object goes", (r) => (r.device = []), "report.device"],
    ["a field named like one of Object's own", (r) => (r.device.constructor = 1), "report.device.constructor"],
    ["a button label that isn't one", (r) => (r.buttons.data = { seen: ["0c:22345"] }), "report.buttons.data.seen[0]"],
    ["a comment with a control character", (r) => (r.comment = "fine\u0007"), "report.comment"],
  ];
  for (const [what, edit, path] of cases) {
    it(`with ${what}`, async () => {
      const { env, sent, db } = setup();
      const r = cobra();
      edit(r);
      const { status: code, body } = await status(env, post(r));
      expect(code).toBe(400);
      expect(body.detail).toContain(path);
      expect(sent).toHaveLength(0);
      expect(db.rows(), "junk doesn't use up the day's allowance").toHaveLength(0);
    });
  }

  it("with a __proto__ field", async () => {
    const { env, sent } = setup();
    const body = JSON.stringify(cobra()).replace(/^\{/, '{"__proto__":{"x":1},');
    const { status: code, body: answer } = await status(env, post(body));
    expect(code).toBe(400);
    expect(answer.detail).toContain("report.__proto__");
    expect(sent).toHaveLength(0);
  });

  it("that isn't JSON, or isn't UTF-8", async () => {
    const { env } = setup();
    expect((await status(env, post("{not json"))).body.error).toBe("bad_json");
    const latin1 = new Request(`https://x.example${PATH}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: new Uint8Array([0x7b, 0x22, 0xe9, 0x22, 0x7d]),
    });
    expect((await status(env, latin1)).body.error).toBe("bad_json");
  });

  it("but not for a field left out or null", async () => {
    const { env } = setup();
    const r = cobra();
    r.comment = null;
    delete r.registry;
    delete r.verdict;
    r.identify.data.firmware = null;
    expect((await status(env, post(r))).status).toBe(200);
  });
});

describe("text from the mouse, not the person", () => {
  it("is cleaned rather than refused, so no line break reaches the subject", async () => {
    const { env, sent } = setup();
    const r = cobra();
    r.device.name = "Razer\r\nBcc: someone@example.com\u0000";
    r.device.interfaces[0].product = "Razer\u0001 Cobra";
    r.dpi.exchanges[0].error = "x".repeat(600);
    expect((await status(env, post(r))).status).toBe(200);
    expect(sent[0].subject).toBe("[MacRazer] Partly tested: RazerBcc: someone@example.com (0x00DB)");
    expect(sent[0].text).toContain('"product": "Razer Cobra"');
    expect(sent[0].text).not.toContain("x".repeat(501));
  });

  it("includes media keys past 0xFF", async () => {
    const { env } = setup();
    const r = cobra();
    r.buttons = { outcome: "passed", exchanges: [], data: { seen: ["0c:223", "09:04"] } };
    expect((await status(env, post(r))).status).toBe(200);
  });

  it("includes a desk full of Razer devices", async () => {
    const { env } = setup();
    const r = cobra();
    r.device.interfaces = Array(40).fill(r.device.interfaces[0]);
    r.device.controlInterface = 39;
    expect((await status(env, post(r))).status).toBe(200);
  });
});

describe("daily caps", () => {
  it("stop one sender at its cap without spending everyone's", async () => {
    const { env, sent, db } = setup({ DAILY_PER_IP: "2", DAILY_TOTAL: "3" });
    for (let i = 0; i < 2; i++) expect((await status(env, post(cobra()))).status).toBe(200);
    for (let i = 0; i < 5; i++) expect((await status(env, post(cobra()))).body.error).toBe("daily_limit");
    expect((await status(env, post(cobra(), { ip: "198.51.100.1" }))).status).toBe(200);
    expect(db.rows().find((r) => r.key === "total")?.count).toBe(3);
    expect((await status(env, post(cobra(), { ip: "198.51.100.2" }))).body.error).toBe("daily_limit");
    expect(sent).toHaveLength(3);
  });

  it("start again the next day", async () => {
    const { env } = setup({ DAILY_PER_IP: "1" });
    expect((await handle(post(cobra()), env, NOW)).status).toBe(200);
    expect((await handle(post(cobra()), env, NOW)).status).toBe(429);
    expect((await handle(post(cobra()), env, new Date("2026-10-04T00:00:01Z"))).status).toBe(200);
  });

  it("aren't spent by a report that didn't go out", async () => {
    let failing = true;
    const { env, db, sent } = setup({ DAILY_PER_IP: "1" });
    const deliver = env.EMAIL.send;
    env.EMAIL = {
      send: async (m) => {
        if (failing) throw Object.assign(new Error("nope"), { code: "E_SENDER_NOT_VERIFIED" });
        return deliver(m);
      },
    };
    for (let i = 0; i < 3; i++) expect((await status(env, post(cobra()))).status).toBe(503);
    expect(db.rows().map((r) => r.count)).toEqual([0, 0]);
    failing = false;
    expect((await status(env, post(cobra()))).status).toBe(200);
    expect(sent).toHaveLength(1);
  });

  it("keep no IP address, and nothing from the report", async () => {
    const { env, db, burstKeys } = setup();
    await status(env, post({ ...cobra(), replyEmail: "person@example.com" }));
    const stored = JSON.stringify(db.rows());
    expect(stored).not.toContain("203.0.113.7");
    expect(stored).not.toContain("person@example.com");
    expect(stored).not.toContain("Cobra");
    expect(db.rows().map((r) => r.key)).toEqual([await ipKey("203.0.113.7", "test-salt", dayOf(NOW)), "total"]);
    expect(burstKeys, "the burst limiter sees the hash too").toEqual([db.rows()[0].key]);
  });

  it("hash an IP differently each day and per salt", async () => {
    const a = await ipKey("203.0.113.7", "s", "2026-10-03");
    expect(await ipKey("203.0.113.7", "s", "2026-10-04")).not.toBe(a);
    expect(await ipKey("203.0.113.7", "t", "2026-10-03")).not.toBe(a);
  });

  it("are cleared once they're more than two days old", async () => {
    const { env, db } = setup();
    for (const day of ["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"]) {
      await handle(post(cobra()), env, new Date(`${day}T12:00:00Z`));
    }
    await cleanUp(db, NOW);
    expect(new Set(db.rows().map((r) => r.day))).toEqual(new Set(["2026-10-01", "2026-10-02", "2026-10-03"]));
  });
});

describe("failures", () => {
  it("of the email service answer 503 and log the code", async () => {
    const { env } = setup({
      EMAIL: {
        send: async () => {
          throw Object.assign(new Error("nope"), { code: "E_SENDER_NOT_VERIFIED" });
        },
      },
    });
    expect((await status(env, post(cobra()))).status).toBe(503);
  });

  it("anywhere else still answer, as 503", async () => {
    const { env } = setup();
    env.DB = { prepare: () => { throw new Error("D1 down"); } } as unknown as Database;
    const response = await main.default.fetch(post(cobra()), env);
    expect(response.status).toBe(503);
  });
});
