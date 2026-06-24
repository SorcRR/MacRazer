# MacRazer: Documentation

A native macOS menu bar app to control Razer mice: battery, DPI, polling rate, RGB lighting,
brightness, and software button remapping. Razer's Synapse does not support macOS, so this
app talks to the mouse directly over USB HID. It is tested on, and works best with, the
Razer Cobra HyperSpeed and the Razer Atheris. By design it detects and tries to control any
Razer mouse using the same protocol family, but models beyond those two are untested.

This document explains how the app is built and how every feature works, so a future Claude
session or a human can pick it up cold. See also:
- [`BRIEF.md`](BRIEF.md), the original research/planning brief and device facts.
- [`../CHANGELOG.md`](../CHANGELOG.md), feature list / history.
- [`../README.md`](../README.md), quick status + build commands.

---

## 1. Overview & how it works at a glance

The mouse speaks Razer's proprietary HID protocol. We did **not** reverse-engineer it from
scratch, we **ported the protocol from OpenRazer's Linux driver** (the Cobra Pro command
set, which the Cobra HyperSpeed reuses). All command bytes were read from the OpenRazer C
source and reimplemented in Swift over Apple's IOKit HID Manager. No kernel extension is
required: Razer mice respond to standard USB HID **feature reports** that any HID-capable
userspace process can send.

```
Razer mouse  <-- HID feature reports (90-byte razer_report) -->  HIDDevice (IOKit)
                                                                       |
                                                  RazerCommands (builds the command bytes)
                                                                       |
                                                  MouseController (poll loop, battery, state)
                                                                       |
                                                  SwiftUI popover / menu bar (NSStatusItem)
```

The app is a SwiftPM **executable** (not an Xcode project). With **no arguments** it launches
the menu bar app; with a subcommand it runs a CLI diagnostic (see §9).

---

## 2. Quick start

Requires macOS 14+ (Apple Silicon), Xcode 16 / Swift 6.1.

```sh
# Develop (inherits your Terminal's permission grants, easiest loop):
swift run MacRazer

# Build a standalone .app:
./Scripts/setup-signing.sh # one-time: stable self-signed identity (see §7)
./Scripts/build-app.sh # to "MacRazer.app"
open "MacRazer.app"
```

**Permissions** (see §7): the app needs **Input Monitoring** (to send/receive HID reports)
and, for button remapping, **Accessibility** (for the event tap). Both are requested in-app.

---

## 3. The HID protocol (ported from OpenRazer)

### 3.1 The wire format, `razer_report` (90 bytes)
Every command is a fixed 90-byte structure sent as a HID **feature report, report id 0**.
Ported in [`RazerReport.swift`](../Sources/MacRazer/RazerReport.swift):

| Offset | Field | Notes |
|---|---|---|
| 0 | status | response: `0x02` success, `0x01` busy, `0x03` failure, `0x04` timeout |
| 1 | transaction_id | **`0x1f` for all Cobra Pro/HyperSpeed commands** |
| 2-3 | remaining_packets | big-endian, usually 0 |
| 4 | protocol_type | 0 |
| 5 | data_size | size of the arguments used |
| 6 | command_class | |
| 7 | command_id | direction bit: get = `0x80\|id` |
| 8-87 | arguments[80] | |
| 88 | crc | XOR of bytes 2..87 |
| 89 | reserved | 0 |

### 3.2 Request/response timing (critical)
`HIDDevice.send()` sends the request (SetReport), waits, then reads the response (GetReport). The wait is
**31 ms** (`RAZER_NEW_MOUSE_RECEIVER_WAIT_US` in OpenRazer). Too short a wait returns status
`0x01` (BUSY) with empty arguments. On BUSY we re-read a few times.

### 3.3 Command reference (verified on hardware)
Built in [`RazerCommands.swift`](../Sources/MacRazer/RazerCommands.swift). VID `0x1532`.

| Operation | class / id | data_size | Notes |
|---|---|---|---|
| Get battery | `0x07` / `0x80` | `0x02` | response `args[1]` is 0-255; `* 100 / 255` gives the %. |
| Get charging | `0x07` / `0x84` | `0x02` | response `args[1]` != 0 = charging. |
| Get / Set DPI | `0x04` / `0x85` / `0x05` | `0x07` | VARSTORE + big-endian x/y; clamp **100-45000** (arbitrary DPI). |
| Get / Set poll | `0x00` / `0x85` / `0x05` | `0x01` | 1000->`0x01`, 500->`0x02`, 125->`0x08` (basic set only). |
| Lighting effect | `0x0F` / `0x02` | varies | extended-matrix on **ZERO_LED (0x00)**; effect ids: none `0x00`, static `0x01`, spectrum `0x03`, wave `0x04`. |
| Get / Set brightness | `0x0F` / `0x84` / `0x04` | `0x03` | value 0-255. **Lives on LOGO_LED (0x04)**, not ZERO_LED, see quirk below. |

### 3.4 Hardware quirks (discovered by testing, important!)
- **Battery works over the 2.4 GHz dongle.** The OpenRazer PR author thought it didn't; the
 real fix was the 31 ms wait + targeting the correct interface.
- **Brightness is on `LOGO_LED` (0x04), not `ZERO_LED`.** Reading brightness on ZERO_LED or
 BACKLIGHT returns status `0x03` (failure). Colors/effects use ZERO_LED; brightness uses
 LOGO_LED. Verified live.
- **Lighting is one group.** The "4 zones" in marketing aren't independently addressable;
 everything is driven together via ZERO_LED.
- **Transient garbage on reconnect.** Right after a USB reconnect the battery can read 0x00
 (0%) or 0xFF (100%) before settling. The controller distrusts these (see §5.1).
- **Two product IDs:** `0x00DA` (wired) and `0x00DB` (wireless dongle).

---

## 4. IOKit HID layer

### `HIDDevice.swift`
- `matchingDevices(vendorId:)` enumerates all HID interfaces for a vendor **without opening
 the manager** (opening the manager grabs the keyboard/mouse interfaces and yields
 `kIOReturnNotOpen` on SetReport, a bug we hit and fixed).
- `open(vendorId:)` picks the **control interface** by score: it must carry a 90-byte feature
 report (`MaxFeatureReportSize >= 90`); we prefer a vendor usage page and the Mouse usage
 (`0x01`/`0x02`) so we don't grab a connected Razer keyboard. Exposes the device's
 `productID` and `productName` (from the USB product string).
- `send()` / `sendWithRetry()` implement the request/response with the 31 ms wait, BUSY
 re-reads, and retry/backoff for the finicky wireless link.

### `HIDMonitor.swift`
IOKit **service** notifications (`IOServiceAddMatchingNotification`, matched + terminated)
for instant USB plug/unplug detection. It does **not** open the device, so it can't
interfere with the control-interface open. Fires `onAppear` / `onRemove` callbacks on the
main queue. (Polling, §5, is the fallback for the wireless-sleep case where the dongle stays
plugged in.)

---

## 5. The controller, `MouseController.swift`

The orchestrator and single source of UI truth (an `ObservableObject`). All blocking HID IO
runs on a serial `io` queue; `@Published` state is updated on the main queue via `publish`.

Published state: `connected`, `batteryPercent`, `charging`, `dpi`, `pollRate`, `brightness`,
`timeEstimate`, `statusText`, `deviceName`, `deviceSupported`, `deviceHasBattery`,
`isRefreshing`, `showPercentInMenuBar`.

### 5.1 Polling & connection logic
- **Adaptive self-rescheduling poll**: every **15 s when connected, 4 s when offline / not
 yet ready**, so disconnects show within ~15 s and reconnects within ~4 s, all without a
 manual refresh.
- **Instant plug/unplug** via `HIDMonitor` to `forceCheck()` (USB removal is definitive, so it
 marks offline immediately, bypassing the debounce).
- **2-failure debounce**: a single transient wireless timeout won't flap the UI to "offline".
- **Reconnect sanity checks** (fixes the 0%/100% jumps): a raw `0` reading is treated as
 "not ready" (keep last value, re-poll fast); and the first post-reconnect reading is
 rejected if it jumps >20% from the last trusted value (transient garbage) until confirmed.
- **Battery-less mice**: if `deviceHasBattery` is false (registry), a successful DPI read is
 the alive-check instead of a battery read, and the battery UI is hidden.

### 5.2 Connect/disconnect sounds
On a connection-state transition (after the first baseline poll), plays a system sound:
**Pop** on connect, **Submarine** on disconnect (`NSSound`, names are constants).

### 5.3 Writes
`setDPI`, `setPollRate`, `setBrightness`, `setStatic/Spectrum/Wave/LightingOff`, each
dispatches a command on the io queue and re-publishes the new value optimistically. While
the popover is open, `setPopoverVisible(true)` polls DPI/poll every 2 s so on-mouse changes
(e.g. the DPI-cycle button) reflect live.

### `BatteryHistory.swift`, time-until-empty estimate
- Logs `(timestamp, %)` samples to `~/Library/Application Support/MacRazer/battery-history.json`.
- Computes a discharge rate by **linear least-squares fit** over samples (needs >=5 samples,
 >=30 min span, >=3% measured drop before it's trusted, otherwise the coarse reading is
 noise and the estimate drifts).
- Persists a **learned discharge rate** (`learnedDischargeRate` in UserDefaults), blended
 (EMA) across sessions and charge cycles, so after a restart/recharge the estimate is
 available **immediately** instead of re-deriving for ~3 hours.
- The estimate is always labelled "(est.)".

### `RazerDevices.swift`, device registry
Maps PID to `{ name, fullySupported, hasBattery }`. The connected device's **name comes from
its own USB product string** (works for any Razer mouse); the registry only adds the
"controls verified" flag (Cobra family) and the battery flag. Unknown mice show their name +
"limited support". This is the extension point for universal support (see §8).

---

## 6. The UI

### 6.1 Menu bar, `AppDelegate.swift` + `MenuBarIcon.swift`
- `NSStatusItem` with a custom-drawn **outlined mouse icon** (vector, drawn in
 `MenuBarIcon.swift`; a template image that adapts to light/dark and **dims to 60% opacity
 when disconnected**) + the battery % text (hideable via a setting; hidden entirely for
 battery-less mice).
- **Left-click** opens the popover; **right-click / control-click** shows an `NSMenu`
 (status line, Open Controls, Refresh Now, Configure Buttons..., Input Monitoring Settings,
 Quit). Items that need a connected mouse are disabled when offline.
- The popover is **dark-appearance forced** (`.darkAqua`) so the Razer green pops, **pre-warmed**
 at launch so it opens instantly, and `animates = false`.

### 6.2 Popover, `PopoverView.swift`
A fixed **320*620** navigable container with three pages and a push/pop slide animation; each
page is a `ScrollView` (so long content scrolls without resizing the popover):

- **Main page**, Control-Center-style frosted cards, each section its own tile:
 - **Header card**: Razer logo (bright green) in a tinted tile + detected device name +
 connection state + status dot. Shows "No mouse connected" when none.
 - **Battery card**: a custom proportional **battery gauge** (fill tracks the exact %,
 colored green >=40% / orange <40% / red <15%), the big % number, a state-colored level
 bar, the time estimate, and a spinner-animated refresh button. Dims when offline.
 - **DPI card**: green slider (100-26000) + preset chips (400/800/1600/3200/6400) + a
 persisted **custom chip** (drag the slider to any value to save it; green-outlined).
 - **Polling card**: segmented 125/500/1000 Hz.
 - **Lighting card**: brightness slider (☀︎) + effect segmented (Static/Spectrum/Wave/Off)
 + colour swatches (true red...pink) + a rainbow "custom" well that opens the colour wheel.
 - **Configure Buttons** card-button to buttons page.
 - **Settings card**: a switch toggle for "Show battery % in menu bar".
 - Live mouse-config sections **grey out + disable when disconnected** (battery stays
 readable; refresh stays active).
- **Colour page**, `ColorPickerPage.swift`: an inline **hue/saturation colour wheel** +
 brightness slider + live preview, applied to the mouse live (throttled). Replaces the old
 system `NSColorPanel`.
- **Buttons page**, `RemapView.swift` embedded (see §6.3).

### 6.3 Button remapping, `ButtonRemapper.swift` + `RemapView.swift`
**Software** remapping via a `CGEvent` tap (the onboard-remap protocol isn't in OpenRazer and
Razer's EULA forbids reverse-engineering it, see CHANGELOG / chat). The tap watches
`otherMouseDown/Up`; for a mapped button it **suppresses the original event and posts the
mapped action** (events the app itself posts are tagged and skipped to avoid loops). Only the
side buttons (Back/Forward = buttons 4/5) emit OS-level events and are remappable; DPI/profile
buttons are handled onboard and never reach macOS.

- Actions: passthrough, **keystroke** (preset shortcuts or a **custom recorder** that
 captures any combo), **mouse** (middle/double click), **media** (play/next/prev/volume/mute).
- Mappings persist to UserDefaults. Needs **Accessibility** permission (banner + Open
 Settings / Re-check in the UI).
- Available both inline (popover buttons page) and as a standalone window
 (`RemapWindowController.swift`, opened from the right-click menu).

---

## 7. Permissions & code signing

| Permission | Why | How |
|---|---|---|
| **Input Monitoring** | Razer mice enumerate as keyboard/mouse HID; macOS gates opening them. | Requested at launch via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`; in-app banner + settings link. |
| **Accessibility** | The `CGEvent` tap for button remapping. | `AXIsProcessTrustedWithOptions`; banner + Open-Settings/Re-check in the remap view. |

**Signing matters for permissions.** TCC binds a grant to the app's code identity. The
build is **ad-hoc signed by default, so every rebuild changes the identity and breaks the
grant** (the toggle looks on but doesn't apply). Fixes:
- `Scripts/setup-signing.sh` creates a **stable self-signed identity** ("Razer Cobra
 Self-Signed"); `build-app.sh` auto-uses it. Grant persists across rebuilds.
- Or just develop with `swift run MacRazer`, which inherits the Terminal's grants.
- `tccutil reset ListenEvent com.macrazer.menubar` clears a stale Input Monitoring grant.

For distribution to other users: every user still grants Input Monitoring once (unavoidable
macOS security). Self-signed = works but Gatekeeper warns ("unidentified developer", one-time
right-click->Open). A clean install needs Developer ID + notarization (paid Apple account).

---

## 8. Extending to other Razer mice

Detection + name display already work for any Razer mouse (read-only, via the USB product
string). To make the **controls** verified for another model:
1. Add its PID/name to `RazerDevices.known` with `fullySupported: true` and the right
 `hasBattery`.
2. Confirm its command dialect matches the Cobra Pro set (transaction id, command variants,
 max DPI, poll rates, LED layout, brightness LED). Port any per-device specifics from
 OpenRazer's `razermouse_driver.c` switch statements / `daemon/.../mouse.py` METHODS.
3. Test each control on hardware (use the CLI diagnostics, §9).

If a model uses a different dialect, generalize `RazerCommands` / add a per-device command
table keyed by PID.

---

## 9. CLI diagnostics

Run from a terminal (uses the Terminal's permission grant). These were how each feature was
verified against hardware:

```sh
swift run MacRazer info # list HID interfaces (find the control one)
swift run MacRazer battery # read battery %
swift run MacRazer dpi [x] [y] # read / set DPI
swift run MacRazer poll [125|500|1000]
swift run MacRazer rgb static ff0000 # or: spectrum | wave | off
swift run MacRazer brightness [0-100] # probes ZERO/BACKLIGHT/LOGO LEDs
swift run MacRazer icon out.png # render the menu bar icon
swift run MacRazer render-ui [offline|color] out.png # render the popover (dev)
swift run MacRazer render-remap out.png
```

(The `render-*` commands use SwiftUI `ImageRenderer`; note it can't rasterize `ScrollView`
or native controls, those show as placeholders.)

---

## 10. File map

| File | Responsibility |
|---|---|
| `main.swift` | Entry point: no args to menu bar app; subcommands to CLI diagnostics. |
| `AppDelegate.swift` | `NSStatusItem`, popover, right-click menu, HIDMonitor wiring, permission request. |
| `MouseController.swift` | Orchestrator: poll loop, connection logic, writes, battery, published state. |
| `HIDDevice.swift` | IOKit HID open/enumerate + request/response send. |
| `HIDMonitor.swift` | IOKit service notifications for plug/unplug. |
| `RazerReport.swift` | 90-byte `razer_report` struct + CRC. |
| `RazerCommands.swift` | Command-byte builders (battery/DPI/poll/RGB/brightness) + Razer constants. |
| `RazerDevices.swift` | PID to {name, supported, hasBattery} registry. |
| `BatteryHistory.swift` | Sample log + learned discharge rate + time estimate. |
| `PopoverView.swift` | Main popover UI + page navigation. |
| `ColorPickerPage.swift` | Inline hue/sat colour wheel page + shared `BackButton`. |
| `ButtonRemapper.swift` | CGEvent tap, action model, presets, persistence, Accessibility. |
| `RemapView.swift` | Button-config UI (inline + window), key recorder. |
| `RemapWindowController.swift` | Standalone window host for the remap UI. |
| `MenuBarIcon.swift` | Vector-drawn menu bar mouse icon (+ triskelion). |
| `RazerLogo.swift` | Embedded official Razer logo (vector PDF, base64) for the header. |

External: `reference/openrazer/` (cloned driver source, the protocol reference, gitignored)
and `reference/openrazer-pr-2583.diff` (the Cobra HyperSpeed PR).
