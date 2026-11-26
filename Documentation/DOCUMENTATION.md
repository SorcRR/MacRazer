# MacRazer: Documentation

A native macOS menu bar app to control Razer mice: battery, DPI, polling rate, RGB lighting,
brightness, and software button remapping. Razer's Synapse does not support macOS, so this
app talks to the mouse directly over USB HID. The Razer Cobra HyperSpeed is the development
mouse; others have been verified from user reports. By design it detects and tries to control
any Razer mouse in the same protocol family. The registry (`RazerDevices.known`) lists every
product id it knows, and README's table says which of them anyone has actually run the probes
against, and how far.

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
and, for button remapping or scroll reversal, **Accessibility** (for the event tap). Both are requested in-app.

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
- **Device mode** (`BLEProtocol.DeviceMode`): read `01 82 00 00`, set `01 02 00 00` with the
 little-endian u16 `03 00` (driver) or `00 00` (normal). In driver mode the firmware reports its
 special buttons to the host as "private keys" instead of acting on them (§6.3.3). It is
 volatile: the mouse is back in normal mode after it sleeps, reconnects or is switched off and
 on, and just after a wake the Cobra took it, read it back and then dropped it as it finished
 starting (§6.3.3). Only `DeviceMode` values can be built into the write
 (`deviceModeRequest(_:)`), it is only sent to a mouse with `RazerDevices.dpiButtonPrivateKeys`,
 and `BluetoothDevice.setDeviceMode(_:readFirst:)` reads first, writes once and reads back
 (`DeviceModeError`), through an exchange that is sent once and never retried.
 `DPIStageTable.nextStage()` is the stage after the active one, for the software DPI cycle.
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
Maps PID to a `RazerDeviceInfo`: name, `unverified` (the features still waiting for a
report; empty means `fullySupported`), `hasBattery`, `hasLighting`,
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
A **380 pt** wide navigable container (760 pt in two columns), as tall as its content, with a main page and sub-pages (colour, Buttons,
Usage, Profiles, What's new) and a push/pop slide animation; each page is a `ScrollView` (so
long content scrolls without resizing the popover):

- **Main page**, Control-Center-style frosted cards, each section its own tile. One column by
 default. Two columns (`PopoverLayout`) when Settings › Appearance › Two-column popover is on
 (`appearance.twoColumnPopover`), and always with more than one Razer device connected (the
 mouse and an accessory, or two accessories). In two columns the header, support, update and
 Bluetooth cards run across the top, and below them are two 303 pt columns: battery, DPI and
 the accessories on the left, the settings sections on the right. With no mouse, the no-mouse
 card takes the left column and the accessories move right. The Buttons page then fills the
 width in two columns (the permission banner or "press a button" hint and how remapping works on the left; the
 buttons, the DPI button and model notes on the right), and the colour page
 puts a 250 pt wheel beside the title, device line, a swatch with its hex code and the
 brightness slider. The other sub-pages are 440 pt wide, centred.
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
 Under Wave, a speed slider (tortoise to hare). The speed byte is `args[4]` of the wave
 command, lower is faster; `WaveSpeed` maps the slider geometrically to 0xC8...0x08, so the
 standard 0x28 sits in the middle and speed changes evenly along it. It can't be read back, so the last one set is kept (`mouseWaveSpeed`, and in
 a profile). Each accessory card has the same slider.
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
 - **Other Razer devices** (`AccessoryController.swift`, `AccessoryCard.swift`,
 `RazerAccessories.swift`): one card per Razer keyboard or mousepad MacRazer knows, independent
 of the mouse being connected. They sit in a recessed tray (a shade darker than the popover,
 hairline edge, a count by the heading) so they read as their own group. `Accessories.shared` lists one `AccessoryController` per unit
 (PID and LocationID), each with its own device handle and queue; two of the same model are
 two cards. Closed, a card is one line: a drawn keyboard or pad (`AccessoryIcon`, lit like
 the device: keys or the pad's edge in its colour, a rainbow for Spectrum and Wave, plain when
 off, unknown or left to Synapse, on a tile tinted the same), name, an "Untested" tag for an untried model, a
 colour dot and the effect. Clicking opens it; which are open is remembered per model
 (`popoverAccessoryExpanded.<pid>`), and a lone accessory starts open. Open, it has the mouse's
 brightness slider and an effect picker with the effects that model has (no Wave on the
 Goliathus pads); its colour swatches stay on screen under every effect (picking one switches
 to Static). On a tested model, an effect not yet seen working gets a line saying so. The effect
 can't be read back, so what MacRazer sets is saved per model (`keyboardLighting.<pid>`, the
 key keyboards had before pads joined) and none is shown picked until it has set one. The
 brightness is re-read whenever the popover opens, and a colour or effect change never resends
 it, so a keyboard's own brightness keys stick.
 - **Follow mouse** (in each card, while there's a mouse): that accessory follows lighting
 the person sets on the mouse (`MouseController.lightingChanges`), never values read from it.
 A pad without Wave runs the mouse's wave as Spectrum. The card then says "Following mouse".
 Saved per model (`accessoryFollowsMouse.<pid>`); a keyboard falls back on the old single
 `keyboardFollowsMouse`.
 - **Use MacRazer** (in each card, only while Razer Synapse runs): off by default, so Synapse
 keeps that accessory and MacRazer writes nothing to it. On, MacRazer puts its lighting on,
 and back on after a wake or reconnect. Saved per model (`accessoryLightingOwner.<pid>`).
 - The colour page names the device it sets once an accessory is plugged in, and goes back to
 the main page if that accessory is unplugged.
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
 - **Scroll wheel on sliders** (`SliderScroll.swift`, `.scrollAdjusts`): while the pointer is
 over a slider, a local `NSEvent` monitor takes vertical scrolls. Up raises the value with
 the natural-scrolling inversion undone. A wheel notch is 1% of the range, rounded to the
 slider's own step and never finer (`SliderScroll.notch`: DPI 250, sleep timer 15 s); a
 trackpad moves in proportion (300 pt crosses the slider), momentum is ignored, and the value
 lands on the slider's step grid. The write goes out 0.3 s after scrolling stops, or when the pointer
 leaves.
- **Appearance**, `PopoverTheme.swift`: Settings › Appearance has a **Theme** (System, Dark,
 Light, Razer Green) and a **Glass effect** switch (off by default), stored as `appearance.theme` and
 `appearance.glass` in UserDefaults. `PopoverLook.resolve` turns theme, glass and the system's
 light or dark mode into one of six looks (light, dark or green glass; solid light #F5F5F7,
 dark #1C1C1E or green #0F1A11). Razer Green is always dark. A **Two-column popover** switch
 (off by default) widens the popover with only the mouse; see the main page above.
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
 captures any combo), **mouse** (middle/double click), **media** (play/next/prev/volume/mute),
 **Launchpad** (`RemapAction.launchpad`), **gesture** (`RemapAction.gesture`, §6.3.2) and
 **DPI Cycle** (`RemapAction.dpiCycle`, only in the DPI button's gesture on a mouse with
 private keys, §6.3.3, and inert anywhere else).
- **Launchpad** has no default keyboard shortcut, so `LaunchpadApp.open()` opens the system
 app through `NSWorkspace` by bundle id: `com.apple.apps.launcher` (Apps, which replaced
 Launchpad on macOS 26, where there is no Launchpad.app), then `com.apple.launchpad.launcher`
 (macOS 15 and earlier); nothing on a Mac with neither. The menus call it "Apps" where Apps is
 the one installed (`LaunchpadApp.label(installed:)`, pure) and "Launchpad" otherwise, and
 list it in the Shortcut menu after the system presets (`launchpadMenuAnchor`). It goes out
 through `apply` like any action, so a test's `actionEmitter` catches it and nothing opens.
- **A release follows its press.** The tap remembers which presses it swallowed
 (`swallowedPresses`) and swallows exactly their releases, whatever changed in between
 (paused or unpaused, remapped, a gesture's hold ended). An app must never see a press
 without its release, which leaves the button held down there. The set survives a reinstall
 of the tap and is cleared when Accessibility goes. The DPI button's F20 (`bridgeKeyIsDown`,
 `handleDpiBridge`) follows the same rule, its key repeats too: a fresh press starts over, and
 the flag survives a reinstall that still asks for the keys (`tapReplaced`). A tap without
 them never sees the release, so there it is dropped.
- **Tap mask** (`ButtonRemapper.eventMask(keyboard:gestures:privateKeyGesture:)`, the wanted one
 in `wantedEventMask`): always `otherMouseDown/Up`; `otherMouseDragged` only while a mapped
 button is a gesture, since drags come at the mouse's polling rate and a tap that doesn't ask
 for them never sees them; key down/up only for the DPI button's F20 bridge; `mouseMoved` only
 while the DPI button of a mouse with private keys is a gesture (§6.3.3), never with keys. A change in what is wanted
 reinstalls the tap (`installTapIfNeeded`). If macOS refuses the tap with keys, it falls back
 to the same mask without them (`keyboardEventsMask`), so gestures keep their drags.
- Mappings persist to UserDefaults. Needs **Accessibility** permission (banner + Open
 Settings / Re-check in the UI).
- Available both inline (popover buttons page) and as a standalone window
 (`RemapWindowController.swift`, opened from the right-click menu).
- Another app's event tap can take a side button's clicks before MacRazer's sees them. Until a
 side button gets through, the page names any such app that's running
 (`ButtonRemapper.competingTapApps`, from `CGGetEventTapList`, Apple's own processes left out).

### 6.3.1 Reverse scrolling, `ScrollSettings.swift` and `ScrollDirection.swift`

**Settings → General → Reverse scrolling on Razer mice** is off by default and saved
once for the app under `reverseScrollingOnRazerMice`. Both vertical and horizontal scrolling
reverse on Razer mice; trackpads and other mice keep their directions. The preference does
not change mouse firmware, profiles, or macOS's Natural scrolling setting.

`ScrollSettings` starts a separate scroll-only event tap only while the preference is enabled,
a Razer mouse is connected, Accessibility is granted, and source identification is available.
The tap has a dedicated thread and run loop. Disabling the setting, disconnecting, revoking
permission, or quitting stops it. Button remapping keeps its existing tap and lifecycle.

`ScrollEventRouter` identifies the underlying HID event's sender. `ScrollSources` preloads
IORegistry sender identities before installation; newly seen senders are resolved on a
separate queue. The event callback only consults cached decisions. Unresolved events pass
through, and negative lookups expire so a newly arriving service can be identified later.
Razer-vendor services match mouse usage or a known mouse PID, including their keyboard
collections. Other Bluetooth identities require an existing recognised mouse model. HID serials
are never compared with Razer protocol serials. No per-unit preference or migration is used.

The sender accessors (`CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID`) are undocumented
system interfaces, resolved dynamically. If unavailable, the switch is disabled. The HID
event is used only to identify the sender; reversal changes the CGEvent line, pixel and
fixed-point fields. The contributor confirmed CGEvent-only reversal works in Safari and a
native `NSEvent.scrollingDelta` reader on their Basilisk V4 HyperSpeed. Hardware behaviour
on other models and macOS versions still needs validation.

Preview: `swift run MacRazer render-settings reversed /tmp/scrolling-settings.png`.
The preview uses a fixed scratch defaults suite, removed before and after rendering.

### 6.3.2 Gesture mode, `GestureRecognizer.swift` + `DockSwipe.swift` + `ButtonRemapper.swift`

A remappable button can be set to **Gesture…** in `RemapView` (every button's menu,
`RemapActionMenu`, has it). Held and moved, the button fires one action per direction;
pressed and released without a swipe, it fires its Click action. A slot that holds one of
four system presets does not fire once: it drives a swipe that follows the pointer (the
"Interactive swipes" bullet below). Every other action is the discrete swipe described here.

- **Data model.** `RemapAction.gesture(GestureBindings)` is saved with the other actions, so a
 gesture needs no new storage key, and a profile carries it too. `GestureBindings` holds five
 ordinary `RemapAction`s: `click`, `up`, `down`, `left`, `right` (`GestureSlot` names them for
 the editor, and `action(for: GestureDirection)` picks by direction). A gesture inside a
 gesture is never offered, and `apply(_:)` ignores one that turns up in saved data.
 `GestureBindings.defaults(click:)` puts `missionControl` up, `.launchpad` down, `spaceRight`
 left and `spaceLeft` right: a swipe moves the Spaces the way a trackpad does, as if the hand
 grabbed the desktop, so left brings the next Space and right the previous one. Down is not
 App Exposé, which as a trackpad swipe does nothing while its trackpad gesture is off, as it
 is out of the box. Only new gestures get the defaults; saved ones keep their choices.
 `defaults(for: button)` takes `originalClick(for:)` as the click, so Back re-posts Back and
 the wheel click re-posts a middle click. `makeGesture(_:)`
 applies the defaults to a button that isn't a gesture yet and keeps the choices of one that
 is, so choosing Gesture… again reopens the editor. `setGestureAction(_:for:of:)` edits one
 slot.
- **The recogniser** (`GestureRecognizer`, a pure struct; the discrete swipe) sums the net movement since the
 hold began (`dx`, `dy`, CGEvent deltas with y growing downward). `move(dx:dy:)` returns a
 `GestureDirection` the first time the larger axis reaches `GestureRecognizer.threshold` (50
 points), and nil after that, so one swipe fires per hold, while the hand is still moving. An
 exact diagonal goes horizontal. Net rather than travelled distance: going right and back is
 still a click. `end()` returns whether the hold was a click and resets the value.
- **Event pipeline** (`ButtonRemapper.handle(type:event:)`). `otherMouseDown` of a gesture
 button calls `beginGesture(_:trigger:)`, which stores a `GestureHold` (the button, its
 bindings and a recogniser) in `gestureHold`; one hold at a time. `otherMouseDragged` goes
 first in `handle` and returns at once when no hold exists; otherwise `handleGestureDrag`
 feeds the deltas to `moveGesture(dx:dy:trigger:)`, which fires the direction's action on the
 swipe. The release (`otherMouseUp` of a swallowed press) calls `endGesture(trigger:)`, which
 fires the click if no swipe fired (no direction fired and no dock swipe began). The press, the drags of the held button and the release
 are swallowed; drags of another button go through. The pointer itself is not frozen.
- **What ends a hold without a click**: a new `otherMouseDown` of any button, pausing
 (`remappingPaused`), changing the button's mapping (`setAction`) or the whole table
 (`setMappings`, a profile), switching device (`setActiveDevice`), the tap being disabled by
 macOS (`tapDisabledByTimeout` / `tapDisabledByUserInput`) or removed, and the Mac waking
 (`cancelGesture`). The release after such a reset is still swallowed, as its press was, and
 fires nothing. While paused a press passes through, so the mouse's own function remains.
- **The system presets as keyboard shortcuts.** `appExpose` ("App Exposé  ⌃↓", key code 125)
 was added for the gesture and is in every button's Shortcut menu. Where a system preset is
 posted as a keystroke (a button's whole mapping, or a gesture where `DockSwipe.isSupported`
 is false or `systemSwipesFollowPointer` is off, below), it goes out as its standard shortcut (⌃↑, ⌃↓, ⌃←, ⌃→) with the flags a real
 arrow key carries (`postedFlags(keyCode:saved:)`), so it has to be on in System Settings ›
 Keyboard › Keyboard Shortcuts › Mission Control.
- **Interactive swipes, `DockSwipe.swift`.** In a gesture, the four presets (`SystemSwipe`:
 `missionControl`, `appExpose`, `spaceLeft`, `spaceRight`) are not typed. They are driven as
 the trackpad's "dock swipe" gesture events, so the Spaces transition, Mission Control or App
 Exposé follows the pointer while the button is held and the Dock finishes or cancels it on
 release. Other slot actions (a custom shortcut, a media key, a mouse click) still fire once at
 50 points. A slot is a system swipe only when it holds the very value the menu put there
 (`SystemSwipe.init?(_:)` compares key code, name and the posted flags with the preset), so the
 same keys recorded as a custom shortcut stay a plain keystroke. Launchpad is never a swipe:
 it opens an app, once at 50 points. The event format is undocumented macOS behaviour, learned
 from Mac Mouse Fix (credited in NOTICE.md, with InstantSpaceSwitcher for the direction) and
 written independently: facts only, no code taken.
  - **App Exposé needs the Dock's trackpad gesture.** The Dock ignores an App Exposé swipe
   while System Settings › Trackpad › More Gestures › App Exposé is off, which it is out of the
   box (`showAppExposeGestureEnabled` in the `com.apple.dock` domain; on macOS 26.3 the swipe
   did nothing there). So `dockSwipeTracker(for:)` asks `DockSwipeOutput.appExposeEnabled`
   (`DockGestures.appExposeEnabled`, read fresh at every hold) and, while it is off, takes App
   Exposé out of the slots (`SystemSwipeSlots.removing`): the slot is then its ⌃↓ shortcut,
   fired once at 50 points by the discrete swipe. Mission Control's and the Spaces' trackpad
   gestures are on out of the box, and those swipes are always sent.
  - **Tracker** (`DockSwipeTracker`, a pure struct fed every pointer move with a time).
   `SystemSwipeSlots` (made once at `beginGesture` by `dockSwipeTracker(for:)`, nil when no slot
   is a system swipe) says which swipe each direction holds. Inside `deadZone` (12 points)
   nothing happens, so a click's drift is still a click. Past it, the larger axis is locked for
   the rest of the hold (an exact diagonal goes horizontal), and the direction decides: a system
   swipe there sends `began` at once, with the dead zone's movement counted; any other action
   leaves the hold to `GestureRecognizer` (state `discrete`). Once swiping, it follows every
   movement along the locked axis, backwards too. `changed` frames are at most
   `minimumFrameInterval` (1/240 s) apart; the end always carries the latest progress.
  - **Sign.** It follows the slots, not the screen: moving towards the slot that holds Space
   Left heads for the Space on the left, whichever slot that is (`progressSign`: Mission
   Control and Space Left -1, App Exposé and Space Right +1). Moving back past the start goes on
   into the opposite slot's swipe only when that slot holds the same swipe the other way
   (`opposite`). Otherwise (another action, None, or the other kind of swipe, which cannot take
   over a swipe under way) the progress is clamped at zero (`keepSign`). With the default
   gesture (Space Right left, Space Left right) the desktop moves with the pointer, as on a
   trackpad: moving right heads for the previous Space. And its vertical axis is mixed:
   Mission Control up is a swipe, Launchpad down an ordinary action, so moving down from the
   start fires Launchpad once at 50 points, while a swipe up taken back down stops at the start
   and fires nothing.
  - **End or cancel, velocity.** `end(at:)` sends `ended` with an exit velocity: a time-weighted
   average of the pointer's speed (`velocitySmoothing`, 0.05 s) times the gain, faded by how
   long the pointer has been still, so a flick finishes a short swipe and a stop leaves it to
   the progress. It sends `cancelled` instead when the progress is zero or the velocity opposes
   it, which is the pointer coming back towards the start, so the swipe snaps back. `cancel()`
   cancels with no velocity.
  - **Progress and scale** (`DockSwipe.Frame.progress`, `DockSwipe.Scale`). Every event carries
   the total so far, not a step. Horizontally one Space is `perSpace(spaces)`: 2 for one or two
   Spaces, else 1 + 1/(n - 1); 3 is assumed (`assumedSpaces`) when the count is unknown. The
   scale is `perSpace / (screen width + 63)` per point (`spaceGap`, the gap the Dock draws
   between Spaces), so the desktop slides about a screen width for a Space. Vertically it is
   `1 / screen height`, so Mission Control is fully open over the height; negative heads for
   Mission Control, positive for App Exposé. The screen is the one under the pointer when the
   hold starts (`Scale.current()`). The Spaces count comes from a private window server call,
   `CGSCopyManagedDisplaySpaces` (with `CGSMainConnectionID`), looked up with `dlsym` in
   `ManagedSpaces` so a macOS without it only loses the count.
  - **Method** (`DockSwipe.Method`, `DockSwipe.method`, worked out once). macOS 26 and earlier
   take the CGEvent fields below (`eventFields`); macOS 27 and later ignore them and take an
   attached IOHIDEvent (`attachedHIDEvent`, below), but only when every private call it needs
   resolves (`DockSwipe.AttachedEvent.missingSymbol`). The pure
   `method(majorVersion:missingSymbol:)` decides, and asks for the symbols only on 27 or later,
   so an earlier macOS never looks them up. `DockSwipe.isSupported` is `method != nil`.
  - **Event format, macOS 26 and earlier** (`DockSwipe.events(for:userData:)`, pure). Each frame
   is two CGEvents, both tagged with `userData` (`ButtonRemapper.magic`) so the tap skips them.
   The first is event type 30 (`swipeEventType`) with gesture type 23 (field 110, the dock
   swipe `IOHIDEventType`); the phase (`Phase`: began 1, changed 2, ended 4, cancelled 8) in
   fields 132 and 134; the kind (`Kind`: horizontal 1, vertical 2) in fields 123 and 165 and,
   as the 32-bit float with those bits, in 119 and 139; the progress as a double in 124 and as
   float bits in integer field 135; field 136 (inverted from device) 1 for vertical and 0 for
   horizontal; on `ended` and `cancelled`, the velocity in 129 and 130; and field 41 set to
   33231, whose meaning is unknown and which is copied because it costs nothing. The second
   event is type 29 (`gestureEventType`) with field 41 alone. The field numbers are
   `CGEventField` raw values and none of this is public API.
  - **Event format, macOS 27 and later** (`DockSwipe.HIDPayload`, pure, and
   `DockSwipe.AttachedEvent`). Each frame is one CGEvent: type 30 (field 55) and the
   `userData` tag, nothing else of the old format, no type 29 event. Attached to it is an
   IOHIDEvent of type 23 (kIOHIDEventTypeDockSwipe) with the phase in its event flags
   (`phase << 24`), the kind as its motion (field `0x170001`), flavor 3
   (kIOHIDGestureFlavorDockPrimary, field `0x170005`) and the progress as a double (field
   `0x170002`, kept by IOKit in 16.16 fixed point). On `ended` and `cancelled` it has a child
   IOHIDEvent of type 9 (velocity) with the velocity in X and Y (`0x90000`, `0x90001`). The
   field numbers are Apple's, from IOHIDFamily's open-source IOHIDEventTypes.h. The progress and
   the velocity are signed for macOS 27 (`HIDPayload.orientation`): flipped while Natural
   scrolling is on (`com.apple.swipescrolldirection` in the global domain, on when absent,
   `DockGestures.naturalScrolling`), kept while it is off, so the swipe goes the same way as
   on macOS 26 and follows the slots. The poster reads the setting as each swipe begins, so one
   swipe keeps one sign. The calls are `IOHIDEventCreate`, `IOHIDEventSetEventFlags`,
   `IOHIDEventSetIntegerValue`, `IOHIDEventSetDoubleValue` and `IOHIDEventAppendEvent` from
   IOKit and `SLEventSetIOHIDEvent` from SkyLight, opened with `dlopen` and looked up with
   `dlsym` once. Ownership: IOHIDEventCreate is a Create-rule call, so each IOHIDEvent made is
   released by `event(for:userData:)`; the parent retains its velocity child; and
   SLEventSetIOHIDEvent keeps a copy in the CGEvent (measured on macOS 27.2.1), so the CGEvent
   owns all a frame needs and nothing leaks per frame. The CGEvent's fields are written
   before the attach: written after it, a field didn't keep its value. The facts come from Mac
   Mouse Fix's macOS 27 path and OpenLogi's hardware-tested sign (NOTICE.md); the code is this
   project's own.
  - **Posting** (`DockSwipePoster`, main thread, session tap, with the `method` it was given).
   Under load the Dock can miss an end and leave the desktop stuck between two Spaces, so each
   end goes out again after 0.2 s and 0.5 s (`endRepeats`), with either method; the next
   swipe's `began`, or another end, stops the repeats still waiting. `ButtonRemapper` keeps the
   last frame of an open swipe (`openDockSwipe`) and `gestureHold`'s `didSet` cancels it on
   every reset that ends a hold, so the Dock is never left halfway; the ends that finish a swipe
   send theirs first. A remapper made for tests (`actionEmitter` set) never posts to the
   session: it takes a recording `DockSwipeOutput`, or has none.
  - **macOS 27 without the calls.** When one of the private calls is missing,
   `DockSwipe.method` is nil, `DockSwipe.isSupported` is false, `DockSwipeOutput.system` returns
   nil, no tracker is made, and the four presets are the keyboard shortcuts above, firing once
   at 50 points.
  - **Hardware.** Tried on a real mouse on macOS 26.3: the Spaces animation follows the
   pointer for horizontal swipes, and a vertical swipe was driven. App Exposé as a swipe did
   nothing there with its trackpad gesture off, hence the fallback above; with the gesture on
   it has not been tried. On macOS 27.2.1 (a Cobra HyperSpeed over Bluetooth) the Spaces and
   Mission Control swipes follow the pointer with the attached method. Not yet tried on macOS
   27: App Exposé as a swipe with its trackpad gesture on, and Natural scrolling turned off.
   Building 200,000 attached events without posting them grew the heap by under 200 bytes. The
   constants (the scale, the dead zone) have not been tuned.
  - **Turning it off** (`ButtonRemapper.systemSwipesFollowPointer`, `RemapView`'s checkbox titled
   `followPointerToggleTitle`, "Mission Control and Spaces follow the pointer"). On by default.
   Off, `dockSwipeTracker(for:)` returns nil, so no tracker is made and the four presets are
   the keyboard shortcuts their slots hold, fired once at 50 points like any other action, for
   a mouse button's hold and the DPI button's long press alike. One global setting: saved in the defaults key `systemSwipesFollowPointerKey`
   (`gestureSystemSwipesFollowPointer`), not per mouse and not in profiles; absent reads as on.
   Holds read it as they start, so a change sets `gestureHold` to nil, which ends the hold and
   cancels an open swipe; writing the value it already has changes nothing. The checkbox shows
   only `if DockSwipe.isSupported`, and the editor's explanation goes by
   `systemSwipesFollowPointerHere` (`dockSwipes != nil` and the setting on). The page is at
   least as tall as the open editor (`gestureEditorHeight`), so the checkbox is never clipped.
- **A gesture's click re-posts the button** (`mouseClickEvents(button:at:source:)`, made with
 `postSource` so the events carry `magic` and pass the tap, and with the button number set
 outright so Back and Forward don't come out as a middle click). It fires at release, so a
 gesture button can't be held to drag.
- **UI.** `RemapView.gestureEditor` lists the five slots with an action menu each (the same
 `RemapActionMenu`, whose None does nothing in a slot and which offers the button's own click
 under Mouse), a key recorder, and the follow-the-pointer checkbox where dock swipes work. `swift run MacRazer render-remap gesture out.png` renders the
 editor from preview data (`ButtonRemapper.loadPreviewState(gesture: true)` puts a gesture on
 button 6).
- **Tests.** `GestureRecognizerTests` (threshold, dominant axis, once per hold, net movement)
 and `ButtonRemapperGestureTests` (swallowing, pass-through while paused, a release following
 its press, the reset rules, nested gestures, defaults, persistence and migration, the tap
 mask), driven through `handle(type:event:)` with synthetic `CGEvent`s and the `actionEmitter`
 hook that records actions instead of posting them. `DockSwipeTests` (the preset-to-swipe
 match, the tracker's dead zone, axis lock, sign, clamp, end versus cancel and velocity, the
 scale, the event fields, the poster's repeated end, the method by macOS version, the attached
 payload and its sign by Natural scrolling, and the attached IOHIDEvent read back, the poster
 sending one event a frame, a cancel keeping the sign the swipe began with, and attached events
 leaving nothing on the heap; those last run only where the app uses that method, macOS 27 and
 later with the calls present (`skipUnlessAttachedMethod`), skip elsewhere, and post nothing)
 and `InteractiveSwipeTests` (the same
 through the tap with a recording `DockSwipeOutput` and a clock the test moves: the swipe
 following a hold, other actions still firing once, no swipe without dock swipes, every reset
 cancelling an open swipe, App Exposé as a swipe or a shortcut by the Dock's setting, the
 default gesture's mixed vertical axis and its Spaces following the hand) and
 `SystemSwipesFollowPointerTests` (the setting: on out of the box, each preset firing its
 shortcut once at 50 points when off for a mouse button and for the Cobra's long press,
 turning it off mid-swipe cancelling the swipe for both, changing it mid-hold ending the hold
 without firing, the saved key being global, and the editor's text).

### 6.3.3 The DPI button and driver mode, `ButtonRemapper.swift` + `DpiDriverMode.swift` + `DpiPrivateKeys.swift` + `BluetoothDevice.swift`

On a mouse with `RazerDevices.supportsDpiButtonBinding` over Bluetooth (the Basilisk V3 X
HyperSpeed `0x00BA` and the Cobra HyperSpeed `0x00DC`) the DPI button's assignment is entry
`0x60` of the mouse's onboard function table, and the Buttons page has a "DPI Button" section
(`DpiCycleBindingSection`, the shared `RemapActionMenu` with the mouse's own functions added).
USB and the 2.4 GHz dongle are not supported: the firmware handles the button onboard there.

- **Choosing** (`ButtonRemapper.dpiButtonAssignment(for:privateKeys:)`, pure): None and
 `.dpiCycle` are the firmware's DPI Cycle (`dpiCycleBlock`); a keystroke whose key
 `BLEProtocol.hidUsage(forMacKeyCode:)` knows, or a mouse button 1 to 5, is written as the
 mouse's own function. Everything else is MacRazer's, saved as `dpiCycleSoftwareAction`
 (`dpiCycleSoftwareAction-<device key>`), in one of two ways:
  - **F20 bridge** (the Basilisk V3 X, `usesDpiBridge`): Double Click and the media keys, as
   before this change, with `.softwareBridge` (F20) written to the entry and `handleDpiBridge`
   firing the action on the key-down. The assignment is nil for anything else there (a key the
   mouse can't type, Launchpad, a gesture), so the menu doesn't offer Gesture… or Launchpad and
   the recorder refuses such a key: the bridge behaves exactly as it did.
  - **Driver mode** (the Cobra, `RazerDevices.dpiButtonPrivateKeys` is
   `DpiButtonPrivateKeys.cobraHyperSpeed`): any action, a gesture included. The entry keeps
   DPI Cycle (an entry already reading it isn't written again), the mouse is put in driver mode
   while the action is saved, and the button's private keys are watched. No F20 and no key
   events in the tap on this mouse.
- **Why driver mode.** The Cobra's DPI button is a tap/hold button: a short press cycles DPI and
 a long press invokes a function only Synapse knows. In normal mode entry `0x60` only fires at
 the release of a short press (an F20 pulse of about 50 ms, nothing while held), and the long
 press has its own entry, `0x80`, off from the factory. A raw HID and Bluetooth trace showed
 nothing at all while the button is held in normal mode. In driver mode (`BLEProtocol.DeviceMode`,
 §4) the firmware stops acting on the button and reports it in HID input report 4
 (`PrivateKeyReport`, an array of the keys held): `short` `0x52`, a pulse of about 55 ms when a
 short press is released; `long` `0xD2`, down once the firmware recognises a long press (about
 a second in; the delay is the firmware's) and held until the release. Over Bluetooth the
 report arrives with its id twice (`04 04 d2 00 ...`), so up to two leading ids are dropped.
 The mouse matches as two HID devices, each delivering every frame and not always in step, so
 `PrivateKeyTracker` counts the frames of the first device to deliver one, until it goes away
 (`sourceGone`, whose releases are marked `deviceGone`).
- **Wanting driver mode** (`DpiDriverModeNeed`, pure): `none` without private keys or a saved
 action; `accessibility` without the tap; `inputMonitoring` without `IOHIDCheckAccess` granted
 (asked last); `relaunch` when it reads as granted but the keys couldn't be watched in this run
 (`privateKeyInputBlocked`); `ready` otherwise, the only one that wants it. Without the rest the
 button is better left cycling DPI than doing nothing. `refreshDpiDriverModeWant` tells
 `MouseController.setDpiDriverModeWanted(_:)` once per change; it runs on every change of
 device, action or tap and wherever the permissions are looked at (`refreshAccessibility`: the
 Buttons page, the popover opening, Re-check). macOS says nothing when a permission is granted,
 so while only one is missing and the mouse is connected a timer looks every
 `permissionRecheckInterval` (3 s). Accessibility is picked up that way; Input Monitoring
 granted while the app runs was not on macOS 26.3 (`IOHIDCheckAccess` kept saying no until a
 reopen), so the page asks for a reopen and offers **Reopen MacRazer** (`reopenApp`: a new
 instance through `AppRelaunch`, then `NSApp.terminate` once it launched, so
 `applicationWillTerminate` gives driver mode back first). The first look in a run that finds
 Input Monitoring is what is missing asks macOS for it (`askForInputMonitoring`,
 `IOHIDRequestAccess`, decided by the pure `asksForInputMonitoring(need:alreadyAsked:)`), so
 that macOS lists the app with a switch; the page's Input Monitoring button asks too. It is
 asked whatever the timer is doing: the timer is usually running already for Accessibility,
 which is asked first, and asking only as it started left the app unlisted. On macOS 27.2.1
 with an ad-hoc signed build, after a `tccutil reset`, the app still did not appear in the
 list and had to be added with the + button; the cause is not established.
- **Lifecycle** (`DpiDriverModeBook`, pure, run by `MouseController.syncDpiDriverMode` on the
 device queue from the poll and on each change). Engaged on each new connection and after each
 wake (`doubtful`), reading first so a mouse already in it isn't written; re-checked at most
 every `recheckInterval` (30 s) to put it back if the mouse fell out (an unanswered check
 changes nothing); a failed change retried at that interval at most `maxAttempts` (3) times
 per connection. Normal mode is written back and read back when it is no longer wanted, where
 this run may have set it (`maybeSet`), and at quit (`restoreDpiDriverModeForQuit`, at most
 `driverModeRestoreTimeout`, 3 s). After a crash nothing writes it back: the button does
 nothing until the mouse sleeps or is power-cycled, or the next run, which reads the mode once
 (`checkLeftover`, `leftoverCheckDelay` 10 s after the connection answers) and writes normal mode
 only if it reads driver mode. Never during a device test. `dpiDriverModeErrorText` gives the
 page a plain sentence for a failure.
- **Settling checks.** Just after a reconnect or a wake the Cobra hasn't finished starting. A
 trace of a real one over Bluetooth showed it accept driver mode and read it back, then reset
 itself to normal mode a few hundred milliseconds later, around its own start-up notifications
 (`0c`, `31`, below): gestures stopped and the button cycled DPI in the firmware until the next
 check, 30 s later. So the first engage after `connectionChanged` or `doubtful` (`fresh`) is
 followed by two quiet checks, `firstSettlingCheckDelay` (1 s) and `secondSettlingCheckDelay`
 (3 s) after it (`engaged(at:wrote:)`). A check that has to write driver mode again (the mouse
 dropped it) starts the two over from that write, at most `maxSettlingRounds` (3) rounds per
 connection or wake; a fall-back the 30 s check finds does the same. They are the book's
 `earlyChecks`, run by a one-shot `asyncAfter` on the device queue
 (`MouseController.scheduleDpiDriverModeEarlyCheck`, occasion `.earlyCheck`), never a timer,
 and called off through a generation counter once the book drops them: a connection change, a
 wake, a change of mind (`setWanted`) or a failed change. An early check only ever checks (it
 never engages, restores or looks for a leftover), gives way to a command waiting on the queue
 and tries again `driverModeEarlyCheckRetryDelay` (0.5 s) later, and keeps the limits of any
 check: a failed write counts against `maxAttempts`, and one that goes unanswered isn't
 repeated (the round's later check still goes).
- **Notifications.** HID input report 5 carries the mouse's own notifications, `05 05 <code>
 ...` over Bluetooth with the id twice (`MouseNoticeReport.notice`, up to two leading ids
 dropped as for report 4). Codes matched (from other projects' notes and the trace, not relied
 on): `02` DPI changed, followed by X and Y big-endian; `09` availability (`09 02` seen at
 sleep, `09 03` documented as wake); `0c` power or connection state; `10` heartbeat; `31`
 battery. The key watcher takes them too and hands them on (`ButtonRemapper.onMouseNotice`,
 `MouseController.dpiDriverModeNoticed`). While driver mode is taken for engaged and the last
 check was answered, `noticed(_:at:)` turns `0c`, `09` and `02` (`MouseNotice.suggestsModeLost`)
 into an immediate check, at most one per `noticeCheckSpacing` (1 s; each notification comes
 from both HID devices and several come together). MacRazer's own DPI changes are told apart by
 time: a `02` that arrives within `ownDpiChangeWindow` (2 s), either side, of its own DPI write
 is that write and calls for nothing. `MouseController.noteOwnDpiChange` stamps the time as
 each DPI write starts and again as it ends (`cycleDpiStage`, `setDPI`, `setDPIStageValue`,
 `applyProfile`). Time rather than the DPI value, since stages can share a value and the
 firmware's next stage could be the one MacRazer last set.
- **A disconnect drops a pending restore.** Driver mode doesn't outlast a connection, so
 `connectionChanged` clears `maybeSet` and with it any restore pending for the connection that
 went (it returns whether one was, traced as dropped). The trace showed why: "no longer wanted"
 came only because the mouse slept and its device went away, and the reconnect then got
 `00 00` before driver mode was wanted again. Quitting writes nothing until driver mode is
 engaged on the new connection. In case only MacRazer's own connection was reopened with the
 mouse still in driver mode, the leftover read is armed again (`leftoverChecked` false). A wake
 (`doubtful`) keeps a pending restore, as it is the same connection, and clearing the action or
 quitting while connected restores as before. An observed removal of the mouse's HID device
 (`beginWakeRecovery` with `discardBluetoothSession`) ends the connection for driver mode at
 once (`dpiDriverModeConnectionLost`).
- **The keys** (`DpiPrivateKeyWatcher`, an `IOHIDManager` on vendor `0x068E` and the product id,
 main thread, Input Monitoring) are watched exactly while `dpiDriverMode` is `.engaged`
 (`privateKeysActive`). A watch that can't start (`startWorks`: no device opened, or the manager
 refused) sets `privateKeyInputBlocked`, so driver mode is no longer wanted; every look at the
 permissions tries an open and close (`canWatch`, nothing sent to the mouse) to lift it. The
 same callbacks take report 5, the mouse's notifications (`MouseNoticeReport`, above).
- **What the keys do** (`handlePrivateKey`, only while engaged, connected and not paused):
 with a gesture, the long key's press starts a hold (`beginGesture` with trigger
 `ButtonRemapper.dpiButton`, -1, and `releaseSlot` `.hold`), the pointer's `.mouseMoved` events
 are the swipe (`handleDpiGestureMove`, never swallowed; the tap asks for them only while this
 button is a gesture, `eventMask(...privateKeyGesture:)`), and the long key's release ends it:
 a dock swipe ends, or, if no swipe happened, the **Hold** slot fires once. The short key fires
 the **Click** slot. `.dpiCycle` there (or in Hold, or in a direction) calls
 `MouseController.cycleDpiStage()` through `perform`: it reads the stage table, writes
 `DPIStageTable.nextStage()` (the first after the last) and publishes it, since the firmware no
 longer cycles DPI in driver mode. Anywhere else `.dpiCycle` is inert. Any other action fires on
 the short key, and a long press does nothing for it.
- **Gesture data.** `GestureBindings.hold` is offered only for this button
 (`gestureSlots(of:)`); a missing `hold` key decodes as None, and it is encoded only when it
 isn't None, so gestures and profiles saved before it are written exactly as before. A new DPI
 gesture (`newDpiGesture`) has the usual swipes and Click and Hold on None, so a short press
 leaves DPI alone until DPI Cycle is chosen; the slot menus offer None and DPI Cycle as separate
 choices (`gestureSlotLeadingChoices`).
- **Writing the entry** (`BluetoothDevice.writeDpiCycleBinding`, both mice): nothing is read or
 written while the mouse says it's on an onboard profile other than 1
 (`DPIButtonEntryError.otherProfileInUse`), since the write goes to profile 1 and the reads see
 the profile in use. The entry is read first, and nothing is written unless it parses
 (`parseDpiButtonBinding`, which also refuses a factory block other than DPI Cycle,
 `.notTheDpiButton`); the write is sent once (`DPIButtonWriteError.notTaken`) and read back
 (`.notReadBack`), with no second write. `MouseController.dpiButtonErrorText` turns each into a
 plain sentence. Entry `0x60` and `SideButtonReset`'s entries `0x04` and `0x05` never overlap.
- **Hardware.** On a Cobra over Bluetooth: the entry write with its read before and after; and,
 through the trace, the device-mode write accepted and read back, the link staying up, the two
 keys as described and normal mode restored on quit. The product code path was then used on
 that mouse: hold and swipe, the short press doing Click, the software DPI cycle stepping one
 stage per press, and the periodic check finding driver mode still set over about an hour. A
 trace of a sleep and wake then showed the mouse dropping driver mode just after it was engaged
 on the new connection. Re-arming after sleep was fixed from that trace (the settling and
 notification checks above, with unit tests), and the fix itself has not yet been re-tried on
 the mouse. Not yet tried: the Hold slot. Driver mode is not enabled on the Basilisk:
 unverified there, and another project saw its link fail writing it.
- **Gesture trace** (`GestureDebugLog.swift`). Off by default; `defaults write
 com.macrazer.menubar gestureDebugLog -bool true` and a relaunch make it append to
 `~/Library/Logs/MacRazer/gesture.log`: holds and pointer deltas, dock swipe frames, the dock
 swipe method once as its poster is made (`SWIPE method: ...`, or `SWIPE method: none, ...`
 with the call that was missing), with the attached method each swipe's `began`, `ended` and
 `cancelled` as sent (`SWIPE attached ...`, with the signed progress, the velocity and the
 Natural scrolling setting), each change of the follow-the-pointer setting, F20
 timing, the mouse's HID input reports other than pointer movement (`GestureDebugHIDWatch`,
 `HIDREPORT`; a keyboard report only when its keys are F13 to F20,
 `GestureDebugReportFilter`), Razer's GATT characteristics and unsolicited notifications,
 read-only probes once per connection (`BLEProtocol.traceProbeKeys`, `BLEREAD`, built only
 from read keys), each device-mode read and write and why (`DEVMODE`: also the settling
 re-checks scheduled and what each found, a notification that called for a re-check, with its
 code, or was MacRazer's own DPI change, an early re-check called off, and a restore dropped
 because its connection went), the private keys (`PRIVKEY`) and the software DPI cycle. It is
 how the findings above were obtained.
- **Tests.** `DpiButtonPrivateKeyTests` (report 4 and the tracker, report 5's notifications,
 the hold, Click and Hold, DPI Cycle, other actions, resets, the watcher and the notifications
 handed on from it, what driver mode needs, the reopen, the permission timer, asking for Input
 Monitoring once, choosing on both mice, the editor and the texts), `DpiDriverModeTests` (`DpiDriverModeBook`, with the settling
 and notification checks, a disconnect dropping a pending restore and the Cobra's sleep and wake
 trace replayed, and `BluetoothDevice.setDeviceMode` with a mouse made of closures),
 `DpiCycleSoftwareBridgeTests` (the entry's checked write, the Cobra enabled over Bluetooth
 only, error texts), `InteractiveSwipeTests` (the Cobra's long press driving a dock swipe),
 `BLEProtocolTests` (device mode, `nextStage`, the trace's reads) and
 `GestureDebugTraceTests`. No test touches a real mouse.

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
 waits for a running step. The full test needs the cable or dongle.
- After Identify, `DeviceTestSteps.capabilities` asks a fixed list of read-only commands once
 (`capabilityReads`: polling_rate2, idle time, scroll settings, profile slots, the per-zone
 effect for every LED id) and, when the button function read answers, the whole button table
 (`readButtonTable`). When no transaction id answers on the interface MacRazer picked, Identify
 also tries the mouse's other interfaces that can carry the control report
 (`HIDDevice.withOtherControlInterfaces`); an answer there means the interface pick is wrong
 for that mouse.
- A mouse on Bluetooth gets a shorter, read-only test (`DeviceTestSteps.bluetoothTest`, the
 window's **Bluetooth test**, or the `bluetoothtest` command). `BluetoothProbe.swift` opens its
 own CoreBluetooth connection, after `MouseController.releaseBluetoothForDeviceTest` closes the
 app's, and reads the GATT services, the PnP ID, the standard battery level and a list of keys
 over Razer's service (`bluetoothReads`). The report has `connection: bluetooth` and a
 `bluetooth` section. Identify is not on the mouse when there is no Razer service, and fails
 when the probe never saw any services (Bluetooth off or not allowed).
- The intro follows the registry row for the connected link (`DeviceTestModel.Support`). Fully
 supported: no test needed, with Test anyway for after a firmware update. Partly supported:
 what works, what still needs testing, and **Test what's missing**, which runs Identify and
 only those steps (`DeviceTestFlow.skipped`). The steps it passes over are recorded as skipped
 with "Already verified", so the report keeps the Worker's format and its verdict reads
 "Partly tested". Both intros also name the mouse's other links still worth a report
 (`RazerDevices.linksToTest`): any row for another link that isn't fully supported, and a
 cable or dongle without a row for a mouse with a battery. Bluetooth only from a row.
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
Asks someone whose mouse could still use a report (`RazerDevices.needsReport`) to run the
device test (§6.4), instead of relying on them finding the menu item.

- **Which mouse.** The connected mouse when a report would help: not on record, partly verified
 on this link, or verified here while another way it connects isn't
 (`RazerDevices.linksToTest`). On Bluetooth only the last kind, since the full test needs USB. With no mouse connected, an unverified one from `HIDDevice.razerMice()` when Input
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
- **What it says.** Three versions, from `RazerDevices.support`: the full test for an unknown
 mouse; for a partly verified one, what works, what's missing and "Run the Test" (the test then
 offers to check only what's missing); for one verified here, which other links still need a
 test and how to switch, with "Got It" instead of a test, since there's nothing to run on this
 link. Got It ends the ask like "Don't ask for this mouse". A row with `hasCableLink: false`
 (the AA-cell mice) is never asked about a cable.
- **The popover card.** At the top of the main page while `showsCard` holds. It stays after the
 window has stopped asking, because it only shows when the person opens the popover anyway.
- **Turning it off.** Settings › General › Ask me to help test my mouse (`supportPrompt.enabled`,
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
 release list and counts the Mac as active for the day by a salted hash of its IP. The check
 itself sends only the app version. Any failure there falls through to GitHub directly, so the Worker can never cost
 anyone an update. One exception skips the throttle: the version just changed and there are no
 notes for it yet.
- **Anonymous daily count.** `AnonymousCountReporter` sends the same Worker request with the
 connected mouse models and the usage stats answer (`stats=yes|no|unasked`), so the reports page
 can count mice in use and how many share. A change of answer is noted in `UsageStats` and goes
 with the next count (`change=said_yes|said_no|turned_off|turned_on`, Delete My Data counts as
 turned off) until the Worker has it. Always on, anonymous like the check. A count goes out
 when there's something new: the first of each UTC day, a mouse not sent yet that day, or a
 changed answer. A failed
 send is silent and retried on the 15-minute tick, at wake and when the network returns. It
 used to ride on the update check, which runs at launch before the mouse is found and then only
 every 3 hours, and missed about half the mice.
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
 gear. One fixed size, with a sidebar of pages, the version and update status at its foot.
 Escape and ⌘W close it. Pages:
 - **General**: Start at login, connection sounds (`connectionSoundsEnabled`), battery % in the
 menu bar (hidden for mice without a battery), crash reports (hidden while crash reporting is
 off, §6.9), Ask me to help test my mouse (§6.5).
 - **Privacy** (only in a build with the Worker): usage stats and deleting what's stored (§6.6).
 - **Appearance**: Theme, Glass effect and Two-column popover (§6.2).
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
| **Input Monitoring** | Razer mice enumerate as keyboard/mouse HID; macOS gates opening them. Also how the DPI button is seen: its F20 through the tap (Basilisk V3 X) and its private keys in driver mode (Cobra, `DpiPrivateKeyWatcher`, §6.3.3). Granted while the app runs, it took effect only once the app was reopened (macOS 26.3), which the Buttons page asks for and offers. | Requested at launch via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`; in-app banner + settings link. Also asked once a run, the first time it is what the DPI button is missing (`ButtonRemapper.askForInputMonitoring`), so macOS lists the app with a switch. |
| **Accessibility** | The `CGEvent` tap for button remapping, gestures and scroll reversal. A DPI button action on the Cobra needs it together with Input Monitoring. | `AXIsProcessTrustedWithOptions`; Open Settings / Re-check in the relevant controls. |

**Signing matters for permissions.** TCC binds a grant to the app's code identity. The
build is **ad-hoc signed by default, so every rebuild changes the identity and breaks the
grant** (the toggle looks on but doesn't apply). Fixes:
- `Scripts/setup-signing.sh` creates a **stable self-signed identity** ("Razer Cobra
 Self-Signed"); `build-app.sh` auto-uses it. Grant persists across rebuilds.
- Or just develop with `swift run MacRazer`, which inherits the Terminal's grants.
- `tccutil reset ListenEvent com.macrazer.menubar` clears a stale Input Monitoring grant.

For distribution to other users: every user still grants Input Monitoring once (unavoidable
macOS security). Self-signed = works but Gatekeeper blocks the first launch. On macOS 15+ the
dialog only has Done, and the user has to click Open Anyway in System Settings > Privacy &
Security (or run `xattr -cr`). Right-click > Open only gets past it on macOS 14 and earlier. A
clean install needs Developer ID + notarization (paid Apple account).

---

## 8. Extending to other Razer mice

Detection + name display already work for any Razer mouse (read-only, via the USB product
string). The device test (§6.4, or `devicetest` in §9) gathers what the steps below need
in one run. To make the **controls** verified for another model:
1. Add its PID/name to `RazerDevices.known` with `unverified: []` (or the features a report
 hasn't shown working yet) and the right
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
swift run MacRazer rgb static ff0000 # or: spectrum | wave [speed hex, lower is faster] | off
swift run MacRazer rgb breathing ff0000 # one colour; two for dual, none for random
swift run MacRazer brightness [0-100] # sweeps LOGO/SCROLL/ZERO/BACKLIGHT LEDs
swift run MacRazer discover # which transaction ids the mouse answers to
swift run MacRazer devicetest # the device test without its window, as JSON on stdout
MacRazer.app/Contents/MacOS/MacRazer bluetoothtest # the read-only Bluetooth test, as JSON; needs the bundle's Info.plist, and the app quit
swift run MacRazer render-device-test review ran sent out.png # one test screen (dev)
swift run MacRazer login-item [on|off] # the "Start at login" registration
swift run MacRazer icon out.png # render the menu bar icon
swift run MacRazer icon-models [dir] # each model's header silhouette
swift run MacRazer appicon [dir] / iconset [dir] # app icon concepts / the .iconset for iconutil
swift run MacRazer render-ui [offline|color|update|updated|whatsnew|…] out.png # popover (dev)
swift run MacRazer render-ui whatsnew installed out.png # the notes without an update to install
swift run MacRazer render-ui keyboard|pad|three [follow|synapse [macrazer]|wave] out.png # accessories next to the mouse
swift run MacRazer render-ui pad color out.png # the colour page naming the pad it sets
swift run MacRazer render-ui twocolumns out.png # two columns with only the mouse
swift run MacRazer render-ui pad color twocolumns out.png # the wide colour page
swift run MacRazer render-remap wide out.png # the two-column Buttons page
swift run MacRazer render-remap gesture out.png # the gesture editor
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
| `SliderScroll.swift` | Scroll wheel and trackpad scrolling on the popover's sliders. |
| `RazerAccessories.swift` | Keyboards and mousepads whose lighting MacRazer sets (PID, kind, transaction id, LEDs, effects), their interface pick, Synapse detection. |
| `AccessoryController.swift` | `Accessories`, the list of plugged-in accessories, and one `AccessoryController` each: its own device and queue, follow-the-mouse, who sets colours while Synapse runs. |
| `AccessoryCard.swift` | An accessory's popover card, and the lighting controls it shares with the mouse's row (swatches, sliders). |
| `RazerTransport.swift` | Transport protocol shared by USB and Bluetooth, plus the shared retry ladder. |
| `BLEProtocol.swift` | Bluetooth LE framing and `RazerReport` translation, the DPI button's entry 0x60 (`DPIButtonBinding`, `parseDpiButtonBinding`), device mode (`DeviceMode`), `DPIStageTable.nextStage()`, the trace's reads. |
| `BluetoothDevice.swift` | CoreBluetooth connection to Razer's vendor GATT service; the DPI button's checked write (`writeDpiCycleBinding`), `setDeviceMode`, the trace's GATT and probe hooks. |
| `BluetoothProbe.swift` | The device test's own Bluetooth connection: GATT services, PnP ID, battery, read-only keys. |
| `StatusItemClick.swift` | Whether a menu bar icon click opens the popover or the right-click menu. |
| `FormControls.swift` | The windows' text fields, comment boxes and choice buttons. |
| `RazerReport.swift` | 90-byte `razer_report` struct + CRC. |
| `RazerCommands.swift` | Command-byte builders (battery/DPI/poll/RGB/brightness) + Razer constants. |
| `RazerDevices.swift` | PID to {name, supported, hasBattery} registry; `dpiButtonPrivateKeys` marks a mouse whose DPI button reports private keys in driver mode (the Cobra HyperSpeed). |
| `DpiPrivateKeys.swift` | The DPI button's private keys (`DpiButtonPrivateKeys`), report 4 (`PrivateKeyReport`), `PrivateKeyTracker`, the mouse's notifications in report 5 (`MouseNotice`, `MouseNoticeReport`), and `DpiPrivateKeyWatcher`. |
| `DpiDriverMode.swift` | `DpiDriverModeState`, `DpiDriverModeNeed` and the pure `DpiDriverModeBook`: when driver mode is wanted, engaged, re-checked (also as the mouse settles and on its notifications), retried and given back. |
| `GestureDebugLog.swift` | The hidden `gestureDebugLog` trace: holds, pointer deltas, the dock swipe method, F20, HID reports (never typed keys), GATT, read-only probes, device mode and private keys, in `~/Library/Logs/MacRazer/gesture.log`. |
| `BatteryHistory.swift` | Sample log + learned discharge rate + time estimate. |
| `PopoverView.swift` | Main popover UI + page navigation. |
| `PopoverTheme.swift` | Settings › Appearance: theme, glass, the resolved look, the popover and window backdrops. |
| `ColorPickerPage.swift` | Inline hue/sat colour wheel page + shared `BackButton`. |
| `ButtonRemapper.swift` | CGEvent tap, action model (`RemapAction`, `GestureBindings`, `GestureSlot`), presets, `LaunchpadApp`, gesture holds, the DPI button (F20 on the Basilisk V3 X, private keys and driver mode on the Cobra), persistence, Accessibility. |
| `GestureRecognizer.swift` | `GestureDirection` and the pure `GestureRecognizer`: the net movement of one hold to at most one swipe. |
| `DockSwipe.swift` | The trackpad's dock swipe from a mouse: the event format (`DockSwipe`), `SystemSwipe` and `SystemSwipeSlots`, the pure `DockSwipeTracker`, `DockSwipeOutput` and `DockSwipePoster`, `DockGestures` (the Dock's App Exposé trackpad setting, Natural scrolling). Mission Control, App Exposé and Spaces follow the pointer in a gesture: CGEvent fields on macOS 26 and earlier, an attached IOHIDEvent on macOS 27 and later. |
| `RemapView.swift` | Button-config UI (inline + window), the shared action menu, gesture editor, DPI button section, key recorder. |
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
