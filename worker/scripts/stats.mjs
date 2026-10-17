// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// `npm run stats`: a summary of the usage stats table, read through Wrangler. Nothing is
// published anywhere; this prints to your terminal. `npm run stats -- --local` reads the
// local database `wrangler dev` uses instead of the deployed one.

import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

/// Each section's query. Tested against the real migrations in test/stats.test.ts.
export const QUERIES = {
  totals:
    "SELECT COUNT(*) AS macs, " +
    "COALESCE(SUM(first_seen >= date('now', '-30 days')), 0) AS new30, " +
    "COALESCE(SUM(last_seen >= date('now', '-90 days')), 0) AS seen90, " +
    "COALESCE(SUM(reinstalls), 0) AS reinstalls FROM installs",
  versions: "SELECT app AS label, COUNT(*) AS n FROM installs GROUP BY app ORDER BY n DESC, app DESC LIMIT 8",
  mice:
    "SELECT MAX(name) AS name, pid, link, MAX(supported) AS supported, COUNT(*) AS n " +
    "FROM install_mice GROUP BY pid, link ORDER BY n DESC, name LIMIT 20",
  os:
    "SELECT CASE WHEN instr(os, '.') > 0 THEN substr(os, 1, instr(os, '.') - 1) ELSE os END || '.x' AS label, " +
    "COUNT(*) AS n FROM installs GROUP BY label ORDER BY n DESC LIMIT 8",
  arch:
    "SELECT CASE arch WHEN 'arm64' THEN 'Apple Silicon' ELSE 'Intel' END AS label, COUNT(*) AS n " +
    "FROM installs GROUP BY label ORDER BY n DESC",
  deleted:
    "SELECT COUNT(*) AS n, COALESCE(SUM(deleted_on >= date('now', '-30 days')), 0) AS n30, " +
    "CAST(AVG(days_used) AS INTEGER) AS avg_days FROM deleted_installs",
  deletedMice:
    "SELECT MAX(name) AS name, COUNT(*) AS n FROM deleted_mice GROUP BY pid, link ORDER BY n DESC, name LIMIT 5",
};

const LINK = { wired: "wired", dongle: "2.4 GHz", bluetooth: "Bluetooth", unknown: "" };

function bars(rows, width = 24) {
  const max = Math.max(1, ...rows.map((r) => r.n));
  return rows.map((r) => `  ${String(r.label).padEnd(16)}${String(r.n).padStart(6)}  ${"█".repeat(Math.max(1, Math.round((r.n / max) * width)))}`);
}

/// The printed summary, from each query's rows.
export function format(results) {
  const t = results.totals[0];
  const d = results.deleted[0];
  const out = [
    "MacRazer usage",
    "",
    `  Macs sharing       ${String(t.macs).padStart(6)}    new in the last 30 days  ${String(t.new30).padStart(6)}`,
    `  Heard from in 90d  ${String(t.seen90).padStart(6)}    reinstalls               ${String(t.reinstalls).padStart(6)}`,
    "",
    "Versions",
    ...bars(results.versions),
    "",
    "Mice                                           Macs  Supported",
    ...results.mice.map((m) => {
      const pid = "0x" + Number(m.pid).toString(16).toUpperCase().padStart(4, "0");
      const link = LINK[m.link] ?? m.link;
      const label = `${m.name}  ${pid}${link ? `  ${link}` : ""}`;
      return `  ${label.slice(0, 44).padEnd(44)}${String(m.n).padStart(6)}  ${m.supported ? "yes" : "no"}`;
    }),
    "",
    "macOS",
    ...bars(results.os),
    "",
    "Chip",
    ...bars(results.arch),
    "",
    `Deleted their data  ${d.n} in all, ${d.n30} in the last 30 days` +
      (d.n ? `, after ${d.avg_days} days on average` : ""),
    ...results.deletedMice.map((m) => `  ${String(m.name).slice(0, 44).padEnd(44)}${String(m.n).padStart(6)}`),
  ];
  if (results.mice.some((m) => !m.supported)) out.push("", "Mice marked no are the ones to add next.");
  return out.join("\n");
}

function run(local) {
  const names = Object.keys(QUERIES);
  const args = [
    "wrangler", "d1", "execute", "macrazer-reports", local ? "--local" : "--remote",
    "--config", local ? "wrangler.toml" : "wrangler.local.toml",
    "--json", "--command", names.map((n) => QUERIES[n]).join(";\n"),
  ];
  const parsed = JSON.parse(execFileSync("npx", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }));
  if (!Array.isArray(parsed) || parsed.length !== names.length) {
    throw new Error(`Expected ${names.length} results from Wrangler, got ${Array.isArray(parsed) ? parsed.length : typeof parsed}`);
  }
  return Object.fromEntries(names.map((n, i) => [n, parsed[i].results]));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  console.log(format(run(process.argv.includes("--local"))));
}
