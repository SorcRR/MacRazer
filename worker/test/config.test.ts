// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
// @ts-expect-error: a plain .mjs script, run by node before each deploy.
import { parseSettings, render, settingsPath } from "../scripts/local-config.mjs";

const template = readFileSync(new URL("../wrangler.toml", import.meta.url), "utf8");
const settings = {
  DESTINATION: "me@mydomain.test",
  SENDER: "reports@mydomain.test",
  DATABASE_ID: "0123abcd-4567-89ef-0123-456789abcdef",
  DOMAIN: "reports.mydomain.test",
};
const line = (toml: string, key: string) => toml.match(new RegExp(`^${key} = "([^"]*)"$`, "m"))?.[1];

describe("the deploy config", () => {
  it("is the template with only the private values swapped in", () => {
    const out = render(template, settings, "settings.env");
    expect(line(out, "destination_address")).toBe("me@mydomain.test");
    expect(line(out, "DESTINATION_ADDRESS")).toBe("me@mydomain.test");
    expect(line(out, "SENDER_ADDRESS")).toBe("reports@mydomain.test");
    expect(line(out, "database_id")).toBe(settings.DATABASE_ID);
    expect(line(out, "pattern")).toBe("reports.mydomain.test");
    expect(out).not.toContain("example.com");
    // Everything else, comments included, is the template's.
    const strip = (t: string) => t.split("\n").filter((l) => !/^(destination_address|DESTINATION_ADDRESS|SENDER_ADDRESS|database_id|pattern) =/.test(l));
    expect(strip(out).slice(2), "after the two-line header").toEqual(strip(template));
  });

  it("refuses anything missing, unknown or malformed", () => {
    const without = ({ SENDER, ...rest }: typeof settings) => rest;
    expect(() => render(template, without(settings), "s")).toThrow("SENDER is missing");
    expect(() => render(template, { ...settings, DESTINATION: 'a@b.test"\nx = "' }, "s")).toThrow("DESTINATION");
    expect(() => render(template, { ...settings, DATABASE_ID: "not-an-id" }, "s")).toThrow("DATABASE_ID");
    for (const bad of ["https://reports.mydomain.test", "reports.mydomain.test/v1", "reports", 'x.test"\nworkers_dev = true']) {
      expect(() => render(template, { ...settings, DOMAIN: bad }, "s")).toThrow("DOMAIN");
    }
    expect(() => render(template, { ...settings, DESTINATON: "typo@x.test" }, "s")).toThrow("Unknown setting DESTINATON");
  });

  it("notices when the template no longer has a line it fills", () => {
    const changed = template.replace(/^SENDER_ADDRESS = .*$/m, "");
    expect(() => render(changed, settings, "s")).toThrow("SENDER_ADDRESS");
  });

  it("reads KEY=value files the way people write them", () => {
    expect(parseSettings('# mine\n\nDESTINATION = "me@mydomain.test"\r\nSENDER=reports@mydomain.test\n')).toEqual({
      DESTINATION: "me@mydomain.test",
      SENDER: "reports@mydomain.test",
    });
    expect(() => parseSettings("just words")).toThrow("Not a KEY=value line");
  });

  it("lives outside the repository unless told otherwise", () => {
    expect(settingsPath({ HOME: "/Users/x" })).toMatch(/\.config\/macrazer-reports\/settings\.env$/);
    expect(settingsPath({ MACRAZER_REPORTS_SETTINGS: "/tmp/s.env" })).toBe("/tmp/s.env");
  });
});
