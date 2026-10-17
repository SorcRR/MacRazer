// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import { STEP_NAMES, type DeviceReport, type Outcome } from "./validate";

/// What `send_email`'s `send()` takes. `to` is always the configured address, never anything
/// from the request, and the binding's `destination_address` refuses any other.
export interface OutgoingEmail {
  to: string;
  from: string;
  replyTo?: string;
  subject: string;
  text: string;
}

export type VerdictKind = "confirmed" | "possibleRegression" | "newAllPassed" | "newPartlyPassed" | "partlyTested";

export interface Verdict {
  kind: VerdictKind;
  passed: string[];
  failed: string[];
  notSupported: string[];
  skipped: string[];
}

/// `DeviceTestVerdict.make` in the app, recomputed here from the step outcomes rather than
/// read from the request, so the subject can't say "Confirmation" for a report that isn't one.
export function verdictOf(report: DeviceReport): Verdict {
  const outcomes: Outcome[] = [
    report.identify.outcome,
    report.battery.outcome,
    report.dpi.outcome,
    report.polling.outcome,
    report.lighting.outcome,
  ];
  const names = (o: Outcome) => STEP_NAMES.filter((_, i) => outcomes[i] === o);
  const passed = names("passed"), failed = names("failed");
  const notSupported = names("notSupported"), skipped = names("skipped");
  const known = report.registry?.fullySupported ?? false;
  let kind: VerdictKind;
  if (failed.length > 0) kind = known ? "possibleRegression" : "newPartlyPassed";
  else if (skipped.length > 0) kind = "partlyTested";
  else kind = known ? "confirmed" : "newAllPassed";
  return { kind, passed, failed, notSupported, skipped };
}

/// `DeviceTestVerdict.subjectPrefix` in the app.
export function subjectPrefix(v: Verdict): string {
  switch (v.kind) {
    case "confirmed": return "Confirmation";
    case "possibleRegression": return "Possible regression";
    case "newAllPassed": return "New mouse: all passed";
    case "newPartlyPassed": return `New mouse: ${v.passed.length} of ${v.passed.length + v.failed.length} passed`;
    case "partlyTested": return "Partly tested";
  }
}

const hex4 = (n: number) => "0x" + n.toString(16).toUpperCase().padStart(4, "0");

export function emailFor(report: DeviceReport, to: string, sender: string): OutgoingEmail {
  const verdict = verdictOf(report);
  const { device } = report;
  const firmware = report.identify.data?.firmware;
  const lines = [
    `${device.name}, product ID ${hex4(device.productID)}` +
      (firmware ? `, firmware ${firmware}` : "") +
      (device.connection ? `, over the ${device.connection}` : ""),
    "",
  ];
  const add = (label: string, names: string[]) => {
    if (names.length > 0) lines.push(`${label}: ${names.join(", ")}`);
  };
  add("Passed", verdict.passed);
  add("Failed", verdict.failed);
  add("Not on this mouse", verdict.notSupported);
  add("Skipped", verdict.skipped);
  lines.push("", `Credit: ${report.credit ?? "(none)"}`);
  lines.push(report.replyEmail ? `Reply to: ${report.replyEmail} (this email's Reply-To)` : "No reply address given.");
  if (report.comment) lines.push("", "Comment:", report.comment);
  lines.push("", "Full report:", "", JSON.stringify(report, null, 2), "", "Sent by MacRazer's device test.");
  return {
    to,
    from: sender,
    ...(report.replyEmail ? { replyTo: report.replyEmail } : {}),
    // The name is checked to be one line of printable text, and the rest is ours.
    subject: `[MacRazer] ${subjectPrefix(verdict)}: ${device.name} (${hex4(device.productID)})`,
    text: lines.join("\n"),
  };
}
