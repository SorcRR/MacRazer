// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

// The shape of a device report, checked field by field. Mirrors `DeviceReport` in
// Sources/MacRazer/DeviceTest.swift. A field this doesn't know is refused, not ignored, so
// nothing reaches the email that wasn't checked. test/fixtures/full-report.json is written
// by the app's own tests with every field set; if the app's report changes, that fixture
// changes, and the tests here fail until this file matches it.

export class ValidationError extends Error {
  constructor(readonly path: string, readonly reason: string) {
    super(`${path}: ${reason}`);
  }
}

type Check = (value: unknown, path: string) => unknown;

const fail = (path: string, reason: string): never => {
  throw new ValidationError(path, reason);
};

/// Control characters, except the line breaks and tabs a comment may have.
const CONTROL_MULTILINE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u2028\u2029]/;
const CONTROL_ANY = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/;

function int(min: number, max: number): Check {
  return (v, path) => {
    if (typeof v !== "number" || !Number.isInteger(v)) fail(path, "not an integer");
    if ((v as number) < min || (v as number) > max) fail(path, `outside ${min}...${max}`);
    return v;
  };
}

const byte = int(0, 255);
const bool: Check = (v, path) => (typeof v === "boolean" ? v : fail(path, "not a boolean"));

/// `max` counts UTF-16 code units, which is what a JS string's length is.
function str(max: number, opts: { multiline?: boolean; pattern?: RegExp } = {}): Check {
  return (v, path) => {
    if (typeof v !== "string") fail(path, "not a string");
    const s = v as string;
    if (s.length > max) fail(path, `longer than ${max}`);
    if ((opts.multiline ? CONTROL_MULTILINE : CONTROL_ANY).test(s)) fail(path, "control character");
    if (opts.pattern && !opts.pattern.test(s)) fail(path, "unexpected format");
    return s;
  };
}

function oneOf(...allowed: string[]): Check {
  return (v, path) => (typeof v === "string" && allowed.includes(v) ? v : fail(path, `not one of ${allowed.join(", ")}`));
}

function list(item: Check, max: number): Check {
  return (v, path) => {
    if (!Array.isArray(v)) fail(path, "not a list");
    const a = v as unknown[];
    if (a.length > max) fail(path, `more than ${max} items`);
    return a.map((x, i) => item(x, `${path}[${i}]`));
  };
}

/// A JSON object with only these keys. `optional` keys may be missing or null: Swift's
/// encoder leaves a nil optional out, and null means the same.
function obj(required: Record<string, Check>, optional: Record<string, Check> = {}): Check {
  return (v, path) => {
    if (typeof v !== "object" || v === null || Array.isArray(v)) fail(path, "not an object");
    const o = v as Record<string, unknown>;
    for (const key of Object.keys(o)) {
      if (!(key in required) && !(key in optional)) fail(`${path}.${key}`, "unknown field");
    }
    const out: Record<string, unknown> = {};
    for (const [key, check] of Object.entries(required)) {
      if (!(key in o)) fail(`${path}.${key}`, "missing");
      out[key] = check(o[key], `${path}.${key}`);
    }
    for (const [key, check] of Object.entries(optional)) {
      if (o[key] !== undefined && o[key] !== null) out[key] = check(o[key], `${path}.${key}`);
    }
    return out;
  };
}

/// An object used as a map: keys from `key`, values from `value`.
function dict(key: Check, value: Check, max: number): Check {
  return (v, path) => {
    if (typeof v !== "object" || v === null || Array.isArray(v)) fail(path, "not an object");
    const entries = Object.entries(v as Record<string, unknown>);
    if (entries.length > max) fail(path, `more than ${max} entries`);
    return Object.fromEntries(entries.map(([k, x]) => [key(k, `${path}{${k}}`), value(x, `${path}.${k}`)]));
  };
}

// MARK: - Limits

export const RAZER_VENDOR_ID = 0x1532;
/// The app caps a comment at 2000 characters. A character can be several UTF-16 code units
/// (an emoji family is eleven), and the app trims a long comment to fit the 16 KB report
/// before sending, so this only has to be roomy, not exact.
export const MAX_COMMENT = 8000;
export const MAX_EMAIL = 254;
/// RecordingChannel.maxExchanges in the app.
const MAX_EXCHANGES = 150;
const ERROR = str(500);
const LED_GROUPS = ["LOGO", "SCROLL", "ZERO", "BACKLIGHT"];
export const STEP_NAMES = ["Identify", "Battery", "DPI", "Polling rate", "Lighting"];
const STEP_KEYS = ["identify", "battery", "dpi", "polling", "lighting", "buttons"];

/// Deliberately loose, like the app's: one @, something either side, a dot in the domain.
const EMAIL = /^[^@\s]+@[^@\s.][^@\s]*\.[^@\s]*[^@\s.]$/;

// MARK: - Schema

const exchange = obj(
  {
    commandClass: byte,
    commandId: byte,
    response: list(byte, 8),
    milliseconds: int(0, 600_000),
  },
  { transactionId: byte, status: byte, error: ERROR },
);

function step(data: Check): Check {
  return obj(
    { outcome: oneOf("passed", "failed", "notSupported", "skipped"), exchanges: list(exchange, MAX_EXCHANGES) },
    { data, error: ERROR },
  );
}

const transactionResult = obj(
  { id: byte, answered: bool, refused: bool },
  { groups: list(oneOf(...LED_GROUPS), LED_GROUPS.length), error: ERROR },
);

const dpiValue = int(0, 100_000);

const reportSchema = obj(
  {
    schemaVersion: int(1, 1),
    appVersion: str(32),
    macOSVersion: str(64),
    device: obj(
      {
        vendorID: int(RAZER_VENDOR_ID, RAZER_VENDOR_ID),
        productID: int(0, 0xffff),
        name: str(128),
        interfaces: list(
          obj({
            productID: int(0, 0xffff),
            product: str(128),
            usagePage: int(0, 0xffff),
            usage: int(0, 0xffff),
            maxFeatureReportSize: int(0, 65_535),
            maxInputReportSize: int(0, 65_535),
            transport: str(32),
          }),
          32,
        ),
      },
      { connection: oneOf("cable", "dongle"), controlInterface: int(0, 31) },
    ),
    identify: step(
      obj(
        { standardAttempts: list(transactionResult, 8), lightingAttempts: list(transactionResult, 8) },
        { firmware: str(32), dpiAttempts: list(transactionResult, 8), standardId: byte, lightingId: byte },
      ),
    ),
    battery: step(obj({}, { raw: byte, percent: int(0, 100), charging: bool })),
    dpi: step(
      obj(
        { restored: bool },
        { original: dpiValue, test: dpiValue, readBack: dpiValue, stages: list(dpiValue, 16), maxProbe: dpiValue },
      ),
    ),
    polling: step(obj({ restored: bool }, { original: int(0, 8000), test: int(0, 8000), readBack: int(0, 8000) })),
    lighting: step(
      obj(
        { groups: dict(oneOf(...LED_GROUPS), byte, LED_GROUPS.length), dimShown: bool, redShown: bool, restored: bool },
        { dimmed: bool, turnedRed: bool },
      ),
    ),
    buttons: step(obj({ seen: list(str(5, { pattern: /^[0-9a-f]{2}:[0-9a-f]{2}$/ }), 128) })),
  },
  {
    registry: obj({
      name: str(128),
      fullySupported: bool,
      hasBattery: bool,
      hasLighting: bool,
      maxDPI: dpiValue,
      transactionId: byte,
      matrixTransactionId: byte,
      brightnessLed: byte,
    }),
    verdict: obj({
      kind: oneOf("confirmed", "possibleRegression", "newAllPassed", "newPartlyPassed", "partlyTested"),
      passed: list(oneOf(...STEP_NAMES), STEP_NAMES.length),
      failed: list(oneOf(...STEP_NAMES), STEP_NAMES.length),
      notSupported: list(oneOf(...STEP_NAMES), STEP_NAMES.length),
      skipped: list(oneOf(...STEP_NAMES), STEP_NAMES.length),
    }),
    comment: str(MAX_COMMENT, { multiline: true }),
    credit: str(256),
    replyEmail: str(MAX_EMAIL, { pattern: EMAIL }),
    exchangesDropped: list(oneOf(...STEP_KEYS), STEP_KEYS.length),
  },
);

// MARK: - Types

export type Outcome = "passed" | "failed" | "notSupported" | "skipped";

/// The parts of a report the Worker reads. The rest only travels in the email.
export interface DeviceReport {
  device: { productID: number; name: string; connection?: string };
  registry?: { fullySupported: boolean };
  identify: { outcome: Outcome; data?: { firmware?: string } };
  battery: { outcome: Outcome };
  dpi: { outcome: Outcome };
  polling: { outcome: Outcome };
  lighting: { outcome: Outcome };
  comment?: string;
  credit?: string;
  replyEmail?: string;
  [key: string]: unknown;
}

/// The report, rebuilt from checked fields only. Throws `ValidationError` naming the first
/// field that's wrong.
export function validateReport(value: unknown): DeviceReport {
  const report = reportSchema(value, "report") as DeviceReport & { device: { interfaces: unknown[]; controlInterface?: number } };
  const control = report.device.controlInterface;
  if (control !== undefined && control >= report.device.interfaces.length) {
    fail("report.device.controlInterface", "points past the interface list");
  }
  return report;
}
