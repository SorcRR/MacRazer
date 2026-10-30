# MacRazer: Documentation

A native macOS menu bar app to control Razer mice: battery, DPI, polling rate, RGB lighting,
brightness, and software button remapping. Razer's Synapse does not support macOS, so this
app talks to the mouse directly over USB HID. Four models have been verified on real
hardware: the Razer Cobra HyperSpeed (the development mouse), the Razer Atheris, the Razer
Basilisk V3 X HyperSpeed and the Razer Viper Ultimate. By design it detects and tries to
control any Razer mouse in the same protocol family; the registry carries twelve product ids,
and README's table says which of them anyone has actually run the probes against.

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
| Lighting effect | `0x0F` / `0x02` | varies | extended-matrix on **ZERO_LED (0x00)**; effect ids: none `0x00`, static `0x01`, breathing `0x02`, spectrum `0x03`, wave `0x04`. Breathing takes one colour (arg size `0x09`), two (`0x0C`) or none for random (`0x06`). |
| Get / Set brightness | `0x0F` / `0x84` / `0x04` | `0x03` | value 0-255. LED group is **per model** (`RazerDevices.brightnessLed`), never ZERO_LED — see quirk below. |

### 3.4 Hardware quirks (discovered by testing, important!)
- **Battery works over the 2.4 GHz dongle.** The OpenRazer PR author thought it didn't; the
 real fix was the 31 ms wait + targeting the correct interface.
- **Brightness lives on a different LED group than effects, and which one is per model.**
 Colors/effects are driven on ZERO_LED for every model so far, but brightness is not: the
 Cobra family answers only on `LOGO_LED` (0x04), while the Basilisk V3 X HyperSpeed — whose
 only lit zone is the scroll wheel — answers only on `SCROLL_LED` (0x01). Every other group
 returns status `0x03` (failure), so a wrong id is not a silent no-op: the brightness slider
 simply stops working. The id is a registry field (`RazerDevices.brightnessLed`, default
 `LOGO_LED`); `swift run MacRazer brightness` sweeps all four groups to find it on a new
 model. Both verified live.
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
- `open(vendorId:)` picks the **control interface** with `HIDDeviceSelection`. It must carry a
 90-byte feature report (`MaxFeatureReportSize >= 90`). Devices are ranked first: a PID in the
 registry wins, then a device with a Mouse usage interface (`0x01`/`0x02`), then the lowest
 location. A device the registry doesn't know is skipped when its product string names a line
 that is never a mouse (`HIDDeviceSelection.nonMouseProductLines`: BlackWidow, Huntsman,
 Tartarus, Blade, Kraken and so on), so a Razer keyboard on its own isn't opened as the mouse.
 Within the winning device, a vendor usage page and the Mouse usage score highest. Exposes the
 device's `productID` and `productName` (from the USB product string).
- `razerMice()` lists the Razer mice plugged in by cable or dongle without opening anything, so
 it works before Input Monitoring. It matches interfaces whose *primary* usage is Mouse, then
 applies the same name filter. The device test and the support prompt use it to find a mouse
 the app can't open yet.
- `send()` / `sendWithRetry()` implement the request/response with the 31 ms wait, BUSY
 re-reads, and retry/backoff for the finicky wireless link.

### `HIDMonitor.swift`
IOKit **service** notifications (`IOServiceAddMatchingNotification`, matched + terminated)
for instant USB plug/unplug detection. It does **not** open the device, so it can't
interfere with the control-interface open. Fires `onAppear` / `onRemove` callbacks on the
main queue. (Polling, §5, is the fallback for the wireless-sleep case where the dongle stays
plugged in.)

### Bluetooth LE: `BLEProtocol.swift` + `BluetoothDevice.swift`
Over Bluetooth the mouse is a plain HID pointer (feature report size 1, no control
interface). Razer's control protocol lives in a separate **vendor GATT service**
(`52401523-F97C-7F90-0E7F-6C6F4E36DB1C`), reverse-engineered by @ungrav in #32 and confirmed
on the Cobra HyperSpeed (Bluetooth PID `0x00DC`, vendor `0x068E`).

- **Framing.** A request is a header `[id, payloadLength, 0, 0, class, command, arg, arg]`
 written to `…1524`, then the payload in 20-byte writes. The reply arrives as notifications
 on `…1525`: a header `[id, length, 0, 0, 0, 0, 0, status]` (status `02` ok, `03` failure,
 `05` not supported) followed by `length` payload bytes. The mouse also sends an
 unsolicited `01 … 03` frame when notifications are enabled, which the assembler skips.
- **Commands (verified on the Cobra HyperSpeed):** battery `05 81 00 01` (0-255, same scale
 as USB), serial `01 83 00 00` (the same serial as over the dongle), DPI stages get/set
 `0B 84 01 00` / `0B 04 01 00`, brightness get/set `10 85 01 <led>` / `10 05 01 <led>` (LOGO
 `04` on the Cobra, like USB), static colour `10 04 00 00`.
- **Stage table.** `[activeID, count]` then per stage `[id, x_lo, x_hi, y_lo, y_hi, 0, 0]`,
 ids from 1, little-endian. Replies drop the last reserved byte. There is no direct "set
 DPI", so selecting a DPI rewrites the table with a new active stage, then reads it back.
- `BLEProtocol` translates `RazerReport` requests and replies, so `MouseController` and the
 `RazerCommands` parsers are shared with USB. Commands without a BLE equivalent (polling
 rate, effects other than static) throw `notSupported`, and the popover hides them.
- **Link choice** (`MouseController.openTransport`): a cable wins. An idle dongle loses to a
 supported mouse on Bluetooth, because the mouse is on one wireless link at a time and the
 dongle would only time out. Detection runs on IOHID (`HIDDevice.bluetoothRazerMouse`), so
 CoreBluetooth and its permission prompt only appear for someone who has such a mouse.

---

## 5. The controller, `MouseController.swift`

The orchestrator and single source of UI truth (an `ObservableObject`). All blocking HID IO
runs on a serial `io` queue; `@Published` state is updated on the main queue via `publish`.

Published state: `connected`, `batteryPercent`, `charging`, `dpi`, `pollRate`, `brightness`,
`timeEstimate`, `statusText`, `deviceName`, `deviceSupported`, `deviceHasBattery`,
`isRefreshing`, `showPercentInMenuBar`.

### 5.1 Polling & connection logic
- **Adaptive self-rescheduling poll.** `BatteryPollStateMachine` holds the connection logic as a
 pure value type (no I/O, no clock), and `MouseController` feeds it each poll's outcome. The
 interval (`BatteryPollStateMachine.Cadence`):
 - **15 s** connected and idle; **4 s** while the pointer has been used in the last 30 s,
 because switching a mouse off happens with a hand on it and nothing on USB reports it.
 - **4 s** for up to 15 polls after a start, reconnect or first failure (settling).
 - **0.5 s** to confirm a failure the UI hasn't acted on yet, so a disconnect settles in about
 a second.
 - **15 s** once the mouse stays silent (asleep or off), instead of 4 s all night.
 - **120 s** with no Razer device enumerated at all. `HIDMonitor` normally catches the replug
 first, so this is only a safety net.
- **Wake-up signal**, `HIDInputWatcher.swift`: a mouse asleep behind its dongle looks the same
 as one that is off, and nothing fires when it wakes. The watcher listens for the mouse's own
 input reports (movement, clicks, wheel) without taking the device from the system and
 triggers an immediate poll. It never reports a disconnect, since silence proves nothing.
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
**Pop** on connect, **Submarine** on disconnect (`NSSound`, names are constants). Settings ›
General can turn them off (`connectionSoundsEnabled`).

### 5.3 Writes
`setDPI`, `setPollRate`, `setBrightness`, `setStatic/Breathing/Spectrum/Wave/LightingOff`, each
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

### Battery extras
- **Discharge curve**, `DischargeCurveModel.swift`: a fuel gauge's percent isn't linear with
 time (a long plateau, then steep drops near full and empty). This learns how long the battery
 actually stays at each percent, one bucket per percent, counting only traversals it watched
 from start to end. Below a minimum number of traversals a bucket falls back to the rate
 estimate. Used for models with a `dischargeCurveModelKey` in the registry.
- **Charge cycles**, `ChargeCycleHistory.swift`: when `BatteryHistory` finishes a cycle (one
 charge to the next), a summary goes into a rolling log. It feeds the trend chart and the
 average battery life per charge. A cycle needs the same minimum span and drop as the rate fit.
- **Usage page**, `UsageGraphView.swift`: the popover's battery sub-page, opened from the chart
 button beside the percentage. It shows the current discharge curve (with the previous charge
 dimmed behind it), the discharge rate, time since the last full charge, and the cross-charge
 trend. It reads only the snapshots `MouseController` publishes on the main queue, never the
 history objects on the `io` queue.
- **Last reading**, `LastBatterySnapshotStore.swift`: the last trusted reading per mouse, kept
 apart from the history so the popover can show an explicitly stale value while the mouse is
 away. Saved at most every so often, and at once on sleep, quit and state changes. Mice not
 seen for a long time are dropped.
- **Low battery alert**, `LowBatteryNotifier.swift`: one notification ("Battery Low") per
 discharge when the battery drops below **15%**. It re-arms at **20%** or when charging starts
 (`Battery.lowThresholdPercent` / `lowRearmPercent` in `CardComponents.swift`).
 `LowBatteryAlertPolicy` is the pure part. A failed charging read counts as unknown, not as
 on battery, so a docked mouse that refuses commands around sleep doesn't get a false alert.
- **Storage**, `Persistence.swift`: battery history, charge cycles and the curve are each a
 versioned JSON file in `~/Library/Application Support/MacRazer/`, written atomically and
 throttled. A format change bumps the version and the data is re-learned instead of failing
 to decode.

### `RazerDevices.swift`, device registry
Maps PID to a `RazerDeviceInfo`: name, `fullySupported`, `hasBattery`, `hasLighting`,
`maxDPI`, transaction ids, the link (`connection`), the header silhouette, and the discharge
curve key. The connected device's **name comes from its own USB product string** (works for
any Razer mouse); the registry adds what has been verified about the model. Unknown mice show their name +
"limited support". This is the extension point for universal support (see §8).

---

## 6. The UI

### 6.1 Menu bar, `AppDelegate.swift` + `MenuBarIcon.swift`
- `NSStatusItem` with a custom-drawn **outlined mouse icon** (vector, drawn in
 `MenuBarIcon.swift`; a template image that adapts to light/dark and **dims to 60% opacity
 when disconnected**) + the battery % text (hideable via a setting; hidden entirely for
 battery-less mice).
- **Left-click** opens the popover; **right-click / control-click** shows an `NSMenu`:
 About MacRazer, the status line, Open Controls, Refresh Now (⌘R), Configure Buttons…, Help
 Support This Mouse… (Test This Mouse… on a verified model), Setup & Permissions…, Settings…
 (⌘,), Check for Updates…, Leave a Tip…, Quit MacRazer (⌘Q). Items that need a connected
 mouse are disabled when offline.
- The popover is **pre-warmed** at launch so it opens instantly, and `animates = false`. Its
 look follows Settings › Appearance (§6.2).
- **Focus.** Opening the popover activates MacRazer so its controls answer the first click.
 Closing it hands focus back to the app the person was in (`PopoverFocusReturn.swift`, pure),
 unless a window of ours opened or the person already moved on.
- **One rule for "busy".** Every window conforms to `AppWindowPresenter` (`AppWindows.swift`),
 and `AppDelegate.isShowingAWindow` asks all of them. Automatic installs, the support prompt
 and the other windows that open on their own wait while any of them, the popover or the menu
 is up. A new window only has to conform to be counted.

### 6.2 Popover, `PopoverView.swift`
A fixed **320*620** navigable container with a main page and sub-pages (colour, Buttons,
Usage, Profiles, What's new) and a push/pop slide animation; each page is a `ScrollView` (so
long content scrolls without resizing the popover):

- **Main page**, Control-Center-style frosted cards, each section its own tile:
 - **Header card**: Razer logo (green) in a tinted tile + detected device name +
 connection state + status dot. Shows "No mouse connected" when none.
 - **Battery card**: a custom proportional **battery gauge** (fill tracks the exact %,
 colored green >=40% / orange <40% / red <15%), the big % number, a state-colored level
 bar, the time estimate, and a spinner-animated refresh button. Dims when offline.
 - **DPI card**: green slider (100-26000) + preset chips (400/800/1600/3200/6400) + a
 persisted **custom chip** (drag the slider to any value to save it; green-outlined).
 - **Settings sections**: the rest, each a compact card of its own, Control-Center style. Each
 shows its current value ("1000 Hz", "Static · 80%", "5 min", the active profile) and the
 settings rows expand in place, each on its own; which are open is remembered
 (`popoverExpandedSections` in UserDefaults). Rows a mouse can't use are left out.
 - **Polling rate**: segmented 125/500/1000 Hz, plus what the rate is good for.
 - **Lighting**: brightness slider (☀︎) + effect segmented (Static/Breathing/Spectrum/Wave/Off)
 + colour swatches (true red...pink) + a rainbow "custom" well that opens the colour wheel.
 The swatches show for Static and Breathing, and set the colour of whichever is on. Breathing
 uses one colour. Over Bluetooth only a static colour has a known command, so the effect
 picker is hidden there.
 - **Power Management** (Basilisk V3 X over Bluetooth): the sleep timer.
 - **Buttons**: opens the buttons page; shows how many buttons are remapped, or "Needs access"
 when saved remaps can't fire without Accessibility permission.
 - Offline, the section rows still open to show last-known settings; their controls and the
 Buttons page are disabled. A failed write turns that row's value red.
 - **Profiles**: quick-switch chips, "+" to save, "Manage Profiles…". A profile
 (`MouseProfile.swift`) is a named snapshot of DPI, polling rate, lighting and button remaps,
 stored per device (`ProfileStore`). The mouse's own profile button only cycles DPI stages in
 firmware and tells the app nothing, so switching is done from the popover
 (`MouseController.applyProfile`). The Profiles page (`ProfilesView.swift`) renames, sets
 active and deletes.
 - **Update card**: when a newer release is found, "Update & Restart" (or the DMG download)
 and a row that opens the **What's new** page (`WhatsNewPage.swift`). After an update, an
 "Updated to …" card until dismissed. See §6.7.
 - **Support card**: see §6.5.
 - Sub-pages that scroll are at least 560 pt tall, so a short (collapsed) main page doesn't squeeze
 them; the colour page keeps the main page's height.
 - The gear in the footer opens the Settings window (§6.8).
 - Live mouse-config sections **grey out + disable when disconnected** (battery stays
 readable; refresh stays active).
 - With **no mouse known at all** (none seen yet, or unplugged), the controls are replaced
 by one card that says how to connect and offers "Look Again" (or the Input Monitoring
 grant, when that's what is missing). A last battery reading is still shown if there is one.
 - Keyboard: **⌘R** refreshes, **⌘,** opens Settings, and **Esc** on any sub-page goes back
 one level instead of closing the popover (except while a key recording or a rename is in
 progress, where Esc cancels that).
 - Swatches, chips and the icon buttons carry VoiceOver labels and tooltips; chips and
 rows get a hover highlight.
- **Appearance**, `PopoverTheme.swift`: Settings › Appearance has a **Theme** (System, Dark,
 Light, Razer Green) and a **Glass effect** switch (off by default), stored as `appearance.theme` and
 `appearance.glass` in UserDefaults. `PopoverLook.resolve` turns theme, glass and the system's
 light or dark mode into one of six looks (light, dark or green glass; solid light #F5F5F7,
 dark #1C1C1E or green #0F1A11). Razer Green is always dark.
 - `AppDelegate` re-applies the look when the setting changes or macOS switches mode, including
 while the popover is open. The popover's appearance is always set explicitly: a nil one would
 follow the menu bar, which macOS tints from the wallpaper.
 - Solid colours and the green tint are painted by `PopoverBackdropView`, which sits in
 NSPopover's frame view just under the content. That view clips to the popover's outline, so
 the fill covers the arrow too. A SwiftUI background would leave the arrow glass. The green
 edge is a SwiftUI overlay on the body (radius 10, measured on macOS 26).
 - Windows get the same look (`AppearanceSettings.track`, `WindowBackdrop`): glass is an
 `NSVisualEffectView` with the popover's material, plus the same tint view, both in the
 window's frame view so the title bar matches; solid looks set the window's background colour.
 The title bar is transparent in every look. Only the popover gets the green edge.
 - Colours: `razerGreen` is the fill (the same in both modes); text and icons use
 `razerGreenText` (#23891A on light). Anything on a green fill uses `onRazerGreen`, a dark green,
 because white on #44D62C is only about 1.9:1. `razerGreenBright` (logo) and `bluetoothBlue`
 also adapt.
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

### 6.4 Device test, `DeviceTest*.swift` + the Worker
The right-click menu's **Help Support This Mouse…** (or **Test This Mouse…** on a verified
model) runs a guided test and builds a report a maintainer can turn into a registry entry.

- `DeviceTest.swift`: the steps (Identify, Battery, DPI, Polling rate, Lighting) as plain
 functions over a channel, the report, and the verdict. Each step puts back what it changes
 before it returns, on every path. Tests drive them against a fake mouse.
- `DeviceProbeSession.swift`: transaction id discovery (every id OpenRazer uses is tried, and
 each result recorded) and the channel that records every command for the report.
- `DeviceTestModel.swift` / `DeviceTestView.swift` / `DeviceTestWindowController.swift`: the
 window. Steps run on `MouseController`'s device queue with the app's own reads paused. Quit
 waits for a running step. The test needs USB; a mouse on Bluetooth is told to switch.
- `DeviceReportOutput.swift`: Copy, the GitHub issue, size fitting, and text limits.
 `DeviceReportSender.swift`: Send, a POST to the Worker.
- `WorkerEndpoint` (`AppInfo.swift`): the Worker's address, from the bundle's Info.plist, where
 `Scripts/build-app.sh` writes it from DOMAIN in the maintainer's private settings file. It is
 never in the repository. A build without it (a clone, a fork, CI, `swift run`) hides Send and
 the reply address, and has no usage stats at all. `MACRAZER_WORKER_URL=http://127.0.0.1:8787`
 points a development build at `wrangler dev`.
- The Worker: a Cloudflare Worker that checks a report against the app's exact format, emails it
 to the maintainer, and keeps only daily counters. Its code and setup are in the private
 SorcRR/macrazer-worker repository. The contract between the two is the fixtures in
 `Tests/MacRazerTests/Fixtures/worker/`: the app's tests write them, and the Worker's CI fetches
 them from this repository and tests against them.

### 6.5 Support prompt, `SupportPrompt.swift` + `SupportPromptView.swift`
Asks someone with a mouse that isn't `fullySupported` to run the device test (§6.4), instead of
relying on them finding the menu item.

- **Which mouse.** The connected mouse when it isn't verified and isn't on Bluetooth (the test
 needs USB). With no mouse connected, an unverified one from `HIDDevice.razerMice()` when Input
 Monitoring is missing. The window then reads "We found a new Razer mouse" and leads with the
 permission. That list is refreshed from the plug monitor (`HIDMonitor`), a second after each
 burst of events, and only while it can matter: the prompt is on and the permission is missing.
 Turning the setting on refreshes it too.
- **When.** `SupportPromptPolicy`, keyed by PID: the cable, dongle and Bluetooth PIDs of one
 mouse are separate links that each need testing, while a second unit of the same model is not.
 The first ask, one reminder after 7 days, then no more windows. Never again after a report is
 sent, or after "Don't ask for this mouse" or Hide. A model later promoted to `fullySupported`
 stops asking without anything clearing its record. Records live in `UserDefaults`
 (`supportPrompt.records`).
- **The moment.** A 5 s timer in `AppDelegate` checks that no window, popover or menu is open,
 starting 10 s after launch so the setup window can come first. It asks only when the same
 mouse is read on two ticks in a row: the controller publishes a new mouse's fields one at a
 time, and a tick in between could pair one mouse's id with another's name.
- **What counts as reported.** `trackReports` watches the device test's Send. Opening the GitHub
 issue counts only in a build that can't send (no `WorkerEndpoint`), since nothing says the issue
 was filed.
- **The popover card.** At the top of the main page while `showsCard` holds. It stays after the
 window has stopped asking, because it only shows when the person opens the popover anyway.
- **Turning it off.** Settings › General › Ask me to test unsupported mice (`supportPrompt.enabled`,
 on by default) silences both the window and the card.

### 6.6 Usage stats, `UsageStats.swift` + the Worker
Opt-in only. Nothing is sent until the person clicks Share. In a build without the Worker (see
`WorkerEndpoint` above) nothing is asked, Settings has no Privacy page, and nothing is sent.

- **Asking.** A new install gets `UsageStatsConsentView` in its own window, once nothing else is
 on screen (the setup window comes first). Someone updating gets `UsageStatsCard` in the
 Updated window instead. Closing either without answering counts as no, and it isn't asked again.
- **The ID.** An HMAC-SHA256 of the hardware UUID (`IOPlatformUUID`) with a fixed app key,
 cut to 16 bytes of hex. The same Mac gets the same ID after a reinstall, the UUID never leaves
 it, and the result can't be matched with what another app gets from the same UUID. It's saved
 in the preferences once worked out, so a UUID that changes in a macOS upgrade doesn't make a
 new Mac.
- **When.** `UsageStatsPolicy`: a `first` ping when nothing was reported yet, `update` when the
 version changed, `mouse` when a mouse connects that this Mac hasn't reported. Launch waits 15 s
 for a mouse, then sends anyway. A failed ping is simply due again, at the next launch or mouse. `swift run` builds never
 send.
- **What.** `UsagePing`: the ID, the event, app and macOS versions, the chip (from
 `hw.optional.arm64`, so Rosetta still counts as Apple Silicon), and the connected mouse with its
 product ID, link and whether it's supported. Settings › Privacy shows this exact JSON.
- **Delete My Data.** Turns sharing off and sends `DELETE /v1/stats/<id>`. The Worker moves the
 row to tables without the ID. If the server can't be reached, the delete is kept and retried at
 every launch and whenever a mouse connects, and no ping goes before it succeeds.
- **Seeing the numbers.** `npm run stats` in the Worker's repository prints a summary.

### 6.7 Updates, `UpdateChecker.swift` + `UpdateInstaller.swift`
No Sparkle: the app is self-signed and shipped as a plain DMG, so there is no appcast. Updates
come from GitHub Releases.

- **Checking.** At most every **3 hours** (`checkInterval`), from launch and a repeating timer,
 plus the menu's Check for Updates…. A build with a Worker asks it first: it passes on GitHub's
 release list and counts the Mac as active for the day by a salted hash of its IP. Settings ›
 Privacy can stop the check from naming the connected mouse models (`sendsMouseModels`, on by
 default). Any failure there falls through to GitHub directly, so the Worker can never cost
 anyone an update. One exception skips the throttle: the version just changed and there are no
 notes for it yet.
- **Release notes.** `ReleaseSpan` picks every published release between the running version
 and the new one, so someone skipping versions reads all of them, not only the latest.
 `ReleaseNotes.parse` turns each GitHub body into a summary and sections, and keeps anything it
 can't classify as plain text. `ReleaseNotesList` draws them the same way on the What's new page
 and in the Updated window. Versions compare as dotted integers (`VersionCompare`).
- **Installing.** "Update & Restart" downloads the DMG, mounts it, and checks the app inside
 (`UpdatePayloadCheck`: the same bundle id, a newer version, an intact signature). Then it swaps
 the bundle in place with `replaceItemAt` and relaunches (`AppRelaunch`). Swapping at the same
 path with the same signing identity keeps the Input Monitoring grant and the login item.
 Where the app can't replace itself (`AppLocation`: still on the disk image, translocated by
 Gatekeeper, in a temp folder, or on a read-only volume), the card offers the plain DMG download
 instead.
- **Automatic installs.** Settings › Updates › Install updates automatically (`autoInstallUpdates`,
 **off by default**). `AutoInstallPolicy` (pure) allows one attempt per version per session,
 never while busy or while anything is on screen (§6.1). A failure about the payload (not a
 newer MacRazer, broken signature) is final for that version. Any other failure is retried at
 the next chance, since the app can run for weeks.
- **After an update.** `UpdateAnnouncement` compares the running version with the last one that
 ran. On the first launch of a new version the Updated window (`UpdatedView.swift`) says the
 update worked and shows what it brought. A first install never claims to be an update, and a
 downgrade is still announced.

### 6.8 Settings, setup and About windows
- **Settings**, `SettingsView.swift` / `SettingsWindowController.swift`: settings for the app
 itself, in a window rather than the popover. Opened with ⌘, from the menu or the popover's
 gear. Sections:
 - **General**: Start at login, connection sounds (`connectionSoundsEnabled`), battery % in the
 menu bar (hidden for mice without a battery), crash reports (hidden while crash reporting is
 off, §6.9), Ask me to test unsupported mice (§6.5).
 - **Privacy** (only in a build with the Worker): mouse models in the update check, usage stats,
 and deleting what's stored (§6.6).
 - **Appearance**: Theme and Glass effect (§6.2).
 - **Updates**: Install updates automatically, the version, and Check Now.
- **Start at login**, `LaunchAtLogin.swift`: `SMAppService.mainApp`, which also lists MacRazer
 in System Settings › General › Login Items. On by default, applied once, on the first launch
 from a real installed location. After that the person's choice stands, including one made in
 System Settings.
- **Setup & Permissions**, `PermissionsView.swift` / `PermissionsWindowController.swift`:
 opens on the very first launch and from the menu. It explains Input Monitoring and
 Accessibility, shows their live state from `PermissionsModel` (`Permissions.swift`) and asks
 for them with the system prompts. `SystemSettingsPanes` holds the deep links into System
 Settings. Input Monitoring only applies after a relaunch, which the window offers.
- **About**, `AboutView.swift` / `AboutWindowController.swift`: version and build, what's new in
 this version, the credit to OpenRazer (the protocol source, and why the project is GPL), and
 the statement that MacRazer is not made by Razer.
- Shared window styling: `titledSection` and the popover's `card` live in `CardComponents.swift`.

### 6.9 Crash reports, `CrashReport*.swift`
Built and tested, but **switched off**: `CrashReporting.deliver` is nil until the Worker accepts
crash reports. While it is nil the app doesn't look for crashes, never shows the window and
hides the setting.

- On launch the app looks for `.ips` files macOS wrote for MacRazer since it last looked
 (`crashReportsHandledThrough`) and offers the newest one.
- `CrashReport` is a summary, never the file: versions, the Mac model, Rosetta, the exception,
 the termination reason, the crash message, the crashed queue and thread, and the Objective-C
 exception's stack. The file's username paths, `crashReporterKey`, boot IDs and registers are
 left out. Stacks are cut to fit the size limit, and the report says so.
- `CrashReportView` shows exactly what would be sent, with an optional comment and reply email
 (`ReportComment` trims comments to fit, shared with device reports). The window doesn't take
 focus, since it usually appears at login while the person is busy with something else.
- Settings › General has the switch (`offerCrashReports`).

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
string). The device test (§6.4, or `devicetest` in §9) gathers what the steps below need
in one run. To make the **controls** verified for another model:
1. Add its PID/name to `RazerDevices.known` with `fullySupported: true` and the right
 `hasBattery` / `hasLighting` / `maxDPI`. If its brightness answers on a group other than
 `LOGO_LED`, set `brightnessLed` too.
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
swift run MacRazer stages # read (and optionally write) the onboard DPI stage table
swift run MacRazer poll [125|500|1000]
swift run MacRazer rgb static ff0000 # or: spectrum | wave | off
swift run MacRazer rgb breathing ff0000 # one colour; two for dual, none for random
swift run MacRazer brightness [0-100] # sweeps LOGO/SCROLL/ZERO/BACKLIGHT LEDs
swift run MacRazer discover # which transaction ids the mouse answers to
swift run MacRazer devicetest # the device test without its window, as JSON on stdout
swift run MacRazer render-device-test review ran sent out.png # one test screen (dev)
swift run MacRazer login-item [on|off] # the "Start at login" registration
swift run MacRazer icon out.png # render the menu bar icon
swift run MacRazer icon-models [dir] # each model's header silhouette
swift run MacRazer appicon [dir] / iconset [dir] # app icon concepts / the .iconset for iconutil
swift run MacRazer render-ui [offline|color|update|updated|whatsnew|…] out.png # popover (dev)
swift run MacRazer render-ui whatsnew installed out.png # the notes without an update to install
swift run MacRazer render-about [notes] out.png
swift run MacRazer render-remap out.png
swift run MacRazer render-support-prompt [noaccess] out.png # the support prompt window
swift run MacRazer render-settings out.png
swift run MacRazer render-updated [nonotes] out.png # the window after an update
swift run MacRazer render-usage-consent out.png
swift run MacRazer render-crash-report [sent] out.png
swift run MacRazer render-permissions out.png
```

(The `render-*` commands use SwiftUI `ImageRenderer`, which can't rasterize native controls —
buttons and sliders show as placeholders. It can't rasterize a `ScrollView` either, so
`render-ui whatsnew`, whose page *is* a scroll view, goes through an `NSHostingView` instead;
that path draws the content but needs an explicit size, since there is no window to supply one.)

---

## 10. File map

| File | Responsibility |
|---|---|
| `main.swift` | Entry point: no args to menu bar app; subcommands to CLI diagnostics. |
| `AppDelegate.swift` | `NSStatusItem`, popover, right-click menu, HIDMonitor wiring, permission request. |
| `MouseController.swift` | Orchestrator: poll loop, connection logic, writes, battery, published state. |
| `HIDDevice.swift` | IOKit HID open/enumerate + request/response send. |
| `HIDDeviceSelection.swift` | Which device and interface to open; tells mice from keyboards. |
| `HIDMonitor.swift` | IOKit service notifications for plug/unplug. |
| `RazerTransport.swift` | Transport protocol shared by USB and Bluetooth, plus the shared retry ladder. |
| `BLEProtocol.swift` | Bluetooth LE framing and `RazerReport` translation. |
| `BluetoothDevice.swift` | CoreBluetooth connection to Razer's vendor GATT service. |
| `RazerReport.swift` | 90-byte `razer_report` struct + CRC. |
| `RazerCommands.swift` | Command-byte builders (battery/DPI/poll/RGB/brightness) + Razer constants. |
| `RazerDevices.swift` | PID to {name, supported, hasBattery} registry. |
| `BatteryHistory.swift` | Sample log + learned discharge rate + time estimate. |
| `PopoverView.swift` | Main popover UI + page navigation. |
| `PopoverTheme.swift` | Settings › Appearance: theme, glass, the resolved look, the popover and window backdrops. |
| `ColorPickerPage.swift` | Inline hue/sat colour wheel page + shared `BackButton`. |
| `ButtonRemapper.swift` | CGEvent tap, action model, presets, persistence, Accessibility. |
| `RemapView.swift` | Button-config UI (inline + window), key recorder. |
| `RemapWindowController.swift` | Standalone window host for the remap UI. |
| `DeviceProbe.swift` | The probes shared by the CLI and the device test. |
| `DeviceProbeSession.swift` | Transaction id discovery and the recording channel. |
| `DeviceTest.swift` | Device test steps, report and verdict. |
| `DeviceTestModel.swift` / `DeviceTestView.swift` | Device test window: flow and screens. |
| `DeviceTestWindowController.swift` | Window host for the device test. |
| `DeviceReportOutput.swift` | Copy, GitHub issue, size fitting and text limits for reports. |
| `DeviceReportSender.swift` | Send: posts a report to the Worker. |
| `SupportPrompt.swift` | When to ask for a device test, and the per-model records. |
| `SupportPromptView.swift` | The support prompt window and its controller. |
| `UsageStats.swift` | Opt-in usage stats: the ID, when to ping, Delete My Data. |
| `UsageStatsView.swift` | The consent window, the Updated window's card, the shared summary. |
| `ButtonCapture.swift` | Listens to the Razer device's buttons during the test. |
| `BatteryPollStateMachine.swift` | Poll cadence, offline debounce, reconnect and charging checks. |
| `HIDInputWatcher.swift` | Polls at once when the mouse sends input after sleeping. |
| `DischargeCurveModel.swift` | Learned time at each battery percent. |
| `ChargeCycleHistory.swift` | Rolling log of finished charge cycles. |
| `LastBatterySnapshotStore.swift` | The last trusted battery reading per mouse. |
| `LowBatteryNotifier.swift` | The low battery notification and when it re-arms. |
| `Persistence.swift` | Versioned, atomic, throttled JSON files for the per-device stores. |
| `UsageGraphView.swift` | The popover's battery usage page. |
| `MouseProfile.swift` | Profiles: the saved snapshot, lighting effects, per-device storage. |
| `ProfilesView.swift` | The popover's page for managing profiles. |
| `DPIStageAccent.swift` | Colours that tell the DPI stages apart in the UI. |
| `CardComponents.swift` | Shared card styles and battery thresholds. |
| `PopoverFocusReturn.swift` | Whether closing the popover gives focus back. |
| `AppWindows.swift` | `AppWindowPresenter`: every window, for the "anything open?" check. |
| `UpdateChecker.swift` | Finds releases, downloads, installs, the announcement after. |
| `UpdateInstaller.swift` | Checks a downloaded app and swaps it in place. |
| `AutoInstallPolicy.swift` | When an automatic install may start. |
| `UpdateAnnouncement.swift` | Whether this launch is the first on a new version. |
| `UpdatedView.swift` / `UpdatedWindowController.swift` | The window after an update. |
| `ReleaseNotes.swift` / `ReleaseSpan.swift` / `VersionedNotes.swift` | Parsing and picking release notes. |
| `WhatsNewPage.swift` | The popover's What's new page and the shared notes list. |
| `VersionCompare.swift` | Dotted-integer version compare. |
| `AppLocation.swift` | Whether the app is at a stable, writable install location. |
| `AppRelaunch.swift` | Opens a new instance, for updates and the permission relaunch. |
| `LaunchAtLogin.swift` | Start at login via `SMAppService`. |
| `SettingsView.swift` / `SettingsWindowController.swift` | The Settings window. |
| `Permissions.swift` | Permission state and System Settings links. |
| `PermissionsView.swift` / `PermissionsWindowController.swift` | The setup and permissions window. |
| `AboutView.swift` / `AboutWindowController.swift` | The About window. |
| `CrashReport.swift` / `CrashReportModel.swift` | Crash summaries and the window's state (off for now). |
| `CrashReportView.swift` / `CrashReportWindowController.swift` | The crash report window. |
| `ReportComment.swift` | Trims a report's comment to fit. |
| `PreviewNotes.swift` | Sample release notes for the `render-*` commands. |
| `MenuBarIcon.swift` | Vector-drawn menu bar mouse icon (+ triskelion). |
| `RazerLogo.swift` | Embedded official Razer logo (vector PDF, base64) for the header. |

The Cloudflare Worker behind Send and the usage stats is in the private SorcRR/macrazer-worker
repository. `Tests/MacRazerTests/Fixtures/worker/` holds the fixtures it tests against.

External: `reference/openrazer/` (cloned driver source, the protocol reference, gitignored)
and `reference/openrazer-pr-2583.diff` (the Cobra HyperSpeed PR).
