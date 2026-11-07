# Project Brief: Razer Cobra HyperSpeed macOS Control App

> Output of a research/planning session with Claude (chat), handed to Claude Code for
> implementation. User is on macOS / Apple Silicon (M2 Max) with the physical mouse
> available for live testing, validate each step against real hardware, don't guess.

## Goal

Build a native macOS menu bar app to control a Razer Cobra HyperSpeed wireless mouse,
which Razer does not support on macOS (Synapse has no Mac build that recognizes this
device). The app should:

- Show battery % as a menu bar (status bar) icon, live-updated.
- Clicking the icon opens a popover with:
 - Battery %, charging status, and an estimated time-until-empty (computed locally from
 observed discharge rate over time, no API for this exists, we derive it).
 - A DPI dial/control (radial or slider) to set DPI.
 - A Chroma/RGB control (color picker + effect mode: static / spectrum / wave minimum).
 - Polling rate dropdown.
 - Button remap table (lower priority, can come after the above works).
- Settings written to the mouse's onboard memory (same as Synapse), so they persist
 without the app running continuously.

## Confirmed device facts

- Vendor ID: `0x1532` (Razer)
- Product ID: `0x00DB` (Cobra HyperSpeed, confirmed via `system_profiler SPUSBDataType`
 and `ioreg` on the user's actual Mac, connected via the 2.4GHz wireless dongle)
- USB product string: "Razer Cobra HyperSpeed", manufacturer "Razer"
- Confirmed connection mode tested: 2.4GHz wireless via stock dongle. Wired (USB-C) and
 Bluetooth not yet tested. Bluetooth does NOT support Razer's proprietary battery-report
 protocol (only 2.4GHz dongle and wired modes do; BT uses a standard HID profile).
- DPI stages per Razer spec: 400, 800, 1600 (default), 3200, 6400, but the mouse likely
 supports arbitrary DPI via Synapse; check OpenRazer for the actual settable range.
- Weight 62g, 4-zone Chroma lighting, 9 programmable controls.
- Official battery life: ~110h on 2.4GHz wireless, ~170h on Bluetooth.

## Why this is feasible: prior art

Not yet officially merged into OpenRazer, but a community member implemented + tested a
driver for it:

- PR: openrazer/openrazer#2583, "Add support for the Cobra HyperSpeed" by dyharlan,
 opened Oct 18 2025, still open/in-progress.
- Feature request issue: openrazer/openrazer#2557.
- Author confirmed from real hardware: DPI, polling rate, and static/spectrum/wave
 lighting all work, using existing **Cobra Pro** command definitions unmodified (copied
 the Cobra Pro driver entry and pointed it at the new product ID).
- **Known issue:** battery-level / low-battery-threshold reads time out over the 2.4GHz
 dongle (dmesg: `razermouse: Command timed out... command_class: 07, command_id.id: 81`).
 Battery reads worked over **wired USB-C** (sysfs values 12-63 observed, exact
 scale/meaning TBD, possibly a raw register value, needs verification). Wireless mode is
 "finicky", dongle can go unresponsive after the mouse sleeps and may need re-seating;
 serial-number queries sometimes fail to probe until then.
- Reference devices already supported (protocol template): Cobra (`0x00A3`), Cobra Pro
 wired (`0x00AF`), Cobra Pro wireless (`0x00B0`). Cobra Pro is the closest match.
- Maintainer z3ntu confirmed: `USB_DEVICE_ID_RAZER_COBRA_HYPERSPEED_WIRELESS 0x00DB`,
 added alongside the existing Cobra Pro defines.

**Implication:** we don't need to sniff USB traffic from scratch. Read the OpenRazer Linux
driver source (C) for Cobra Pro + the HyperSpeed PR diff, and port the protocol logic to
Swift + IOKit HID on macOS. The hard reverse-engineering is already done.

## Key source files (cloned to `reference/openrazer/`)

Repo: https://github.com/openrazer/openrazer

Priority:
- `driver/razercommon.h` / `.c`, core `razer_report` struct (status, transaction_id,
 remaining_packets, protocol_type, data_size, command_class, command_id, arguments[],
 crc), plus `get_razer_report()`, `razer_send_control_msg()`, `razer_get_usb_response()`,
 CRC calc. **Understand this struct first.**
- `driver/razerchromacommon.h` / `.c`, command builders for DPI, polling rate, lighting
 (`razer_chroma_misc_set_dpi_xy`, `razer_chroma_standard_set_led_effect`,
 `razer_chroma_misc_set_polling_rate`). Literal command_class/command_id/argument bytes
 to replicate in Swift.
- `driver/razermouse_driver.c` / `.h`, mouse driver. Search `COBRA_PRO` for which
 chromacommon functions it calls for DPI/RGB/polling/battery, and device-ID switch
 branches. Look for `razer_get_battery()` / command_class `0x07` battery logic.
- PR #2583 diff (`reference/openrazer-pr-2583.diff`), smallest delta: the new device ID
 define + switch branches routing HyperSpeed through Cobra Pro logic.
- `driver/razermouse_driver.h` device-ID `#define`s: `..._COBRA_PRO_WIRED` (0x00AF),
 `_WIRELESS` (0x00B0), new `..._COBRA_HYPERSPEED_WIRELESS` (0x00DB).

Secondary:
- openrazer Python daemon/pylib, how userspace talks to the kernel driver (less relevant;
 we go straight to HID from Swift).
- `1kc/razer-macos`, existing Electron menu bar app porting OpenRazer to a Node native
 addon on macOS. Inspect HOW they talk to IOKit HID (opening the device, feature reports,
 permissions/entitlements). Proves OpenRazer-style HID commands work from macOS userspace
 with no kernel extension, Razer mice respond to standard HID feature reports, exactly
 what IOKit's HID Manager exposes in Swift.

## Architecture decisions (made during planning)

- **Language/framework:** Native Swift + SwiftUI. `NSStatusItem` for the menu bar icon,
 `NSPopover` for the dropdown UI (the pattern macOS's own Bluetooth/WiFi/Battery use).
- **HID:** IOKit HID Manager (`IOHIDManager`, `IOHIDDevice`) to open the device by
 vendor/product ID and send/receive feature reports directly. No kernel extension.
- **Persistence:** write directly to the mouse's onboard memory via the same HID commands
 Synapse/OpenRazer use, settings survive even if our app isn't running.
- **Battery polling:** background timer (~30-60s). Given the wireless reliability issue,
 tolerate timeouts gracefully, retry with backoff, fall back to "last known" rather than
 crashing or showing an error on every transient failure.
- **Time-until-empty:** no device API. Log battery % + timestamp locally every poll
 (JSON/SQLite), derive rolling discharge-rate-per-hour, extrapolate to 0%. Poor on day
 one, improves with data. Label clearly as an estimate.
- **DPI control:** radial/dial in the popover. Confirm from chromacommon whether the
 protocol supports arbitrary DPI or only the 5 preset stages, determines continuous vs
 snap-to-stage.
- **RGB/Chroma:** color picker + effect mode (static / spectrum / wave). 4-zone, check if
 zones are independently addressable or group-only in the existing protocol.
- **Polling rate:** dropdown (125/500/1000Hz, possibly higher, 2000/4000/8000Hz was
 unresolved for wired; for wireless stick to what Cobra Pro supports).
- **Button remapping:** later phase. Requires modeling the 9 controls and writing remap
 tables via HID. Scope after core DPI/RGB/battery/polling work end-to-end.

## Build order (risk-first)

1. Read the source files above (clone done, `reference/openrazer/`).
2. **Battery read**, read-only, lowest risk, validates HID works from Swift/IOKit. Test
 over the 2.4GHz dongle (primary mode); expect/handle the timeout issue.
3. **DPI write**, next-lowest risk (single feature report, confirmed working on this
 device by the PR author).
4. **Polling rate**, same pattern as DPI.
5. **RGB/Chroma**, static first, then spectrum/wave.
6. **Menu bar UI shell** (NSStatusItem + NSPopover), can be built in parallel once battery
 read works.
7. **Time-until-empty estimation**, once battery polling is stable with real % data.
8. **Button remapping**, last, separate phase.

## Open questions to resolve via testing

- Exact byte values/struct layout for the battery-read command (command_class `0x07`;
 exact command_id + argument bytes from chromacommon, not just the dmesg log).
- Whether the sysfs battery range (12-63) is a raw register scale needing conversion to %,
 or something else, verify against the driver's parsing for Cobra Pro (likely a
 `* 100 / 255` style scaling).
- Whether DPI supports arbitrary values or only 5 fixed stages.
- Whether the 4 Chroma zones are independently addressable.
- Real-world reliability of battery reads over this dongle/firmware, may need retry/backoff
 tuning from live testing.

## User environment

- MacBook, Apple Silicon M2 Max, macOS (Apple Silicon native).
- Mouse via 2.4GHz wireless dongle (confirmed at OS/USB level, shows in system_profiler
 and ioreg).
- Comfortable with terminal/bash; can run diagnostics and report output.
