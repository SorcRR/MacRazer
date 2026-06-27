# Changelog

All notable changes to this project. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). The project is **pre-release** (0.x) —
expect rough edges until 1.0.

## [Unreleased]

### Added
- **Battery usage graph.** A chart-icon button beside the battery percentage opens a new page
 showing the current discharge curve (live, since the last charge), the current discharge
 rate, time since the last full charge, and a bar chart of the last 10 charge cycles with
 their average length. Past cycles are persisted per device alongside the existing battery
 history.

### Changed
- Time estimates (the battery card's "~Xh Ym left" and the new usage stats) now break down
 into days once they pass 24 hours, e.g. "~1d 4h", instead of showing raw hour counts.

### Fixed
- **Implausible battery jump guard now stays active permanently**, not just for the first read
 after a reconnect — previously, once the device was marked "ready," a single corrupted
 reading (any time) was trusted outright as the new baseline with no sanity check.
- **A flaky serial-number read on reconnect no longer fragments a device's battery history.**
 If the serial probe fails transiently, the previous session's device key is now reused
 instead of falling back to a PID-only key, which used to split one mouse's history across
 two on-disk files.
- **Button-remap event tap is now torn down when Accessibility is revoked** while the app is
 running, instead of leaving a stale `CGEventTap`/run-loop source registered indefinitely.
- **Corrupted HID responses are now logged.** Incoming reports' CRC is checked against the
 wire format's own integrity byte and a mismatch is logged to stderr (diagnostic only — the
 reading still surfaces, since silently rejecting on every mismatch isn't safe without more
 data on how reliably real hardware sets the CRC).
- **Battery level bar no longer flashes red before the first reading.** "No data yet" (nil)
 was being treated the same as 0% battery; it now renders neutral until a real value arrives.
- **`HIDMonitor`'s IOKit callback context is now properly retained** and released via a new
 `invalidate()` (called on app termination), removing a theoretical use-after-free if a
 notification were already queued on the main queue at the moment the monitor is deallocated.

### Docs
- README notes the one known case where two devices share settings: identical mice of the
 same model that don't expose a hardware serial number have no other stable identifier.

## [0.1.3] — 2026-06-24

### Added
- **Bluetooth-mode detection.** When a Razer mouse is connected over Bluetooth (where Razer's
 control protocol isn't available), the popover now explains it and prompts switching to the
 2.4 GHz dongle or USB-C, instead of just showing a bare "offline".
- **Connection-type indicator.** A small chip beside "Connected" in the popover header shows
 whether control is running over the **2.4 GHz** dongle or a **wired** USB-C cable.

### Docs
- README and the first-run setup screen note that the mouse must be connected over 2.4 GHz or
 USB-C, not Bluetooth.

## [0.1.2] — 2026-06-24

### Added
- **First-run setup & permissions screen.** A dedicated window (shown automatically whenever the
 required **Input Monitoring** permission is missing — and reopenable any time from the menu
 bar's "Setup & Permissions…") explains the two macOS permissions MacRazer needs — Input
 Monitoring (for talking to the mouse) and **Accessibility** (optional, only for button
 remapping) — with live status and native grant prompts. Handles the macOS "grant needs a
 relaunch" gotcha with a **Quit & Relaunch** action and an explanatory tip, and shows the
 detected mouse as positive confirmation once permissions are right.

### Changed
- Permission handling is consolidated into a single `PermissionsModel`; the menu's old
 "Input Monitoring Settings…" item is replaced by the always-available "Setup & Permissions…".

### Fixed
- `Scripts/setup-signing.sh` now works on OpenSSL 3.x (passes `-legacy` and a real PKCS#12
 password), so the stable code-signing identity can be created without a "MAC verification
 failed" error.

## [0.1.1] — 2026-06-24

### Changed
- **Button-remapping event tap is now scoped to the extra mouse buttons only.** It no longer
 observes primary left/right clicks — those were tapped purely for a one-off button-detection
 diagnostic (used to confirm the scroll-wheel click remaps correctly), now removed.
- Popover footer shows the app's **real bundle version** instead of a hardcoded string, so it
 stays accurate across releases.

### Docs
- README: added app screenshots.

## [0.1.0] — 2026-06-24

Native macOS menu bar app to control a Razer Cobra HyperSpeed (and, by design, any Razer
mouse), a feature Razer's Synapse doesn't provide on macOS. Built by porting OpenRazer's
Cobra Pro HID protocol to Swift + IOKit.

### Core device control
- **Battery level** read over the 2.4 GHz wireless dongle (and wired), proven working
 despite the OpenRazer PR's doubts (the fix was the 31 ms request/response wait + targeting
 the correct control interface).
- **Charging status** read and shown.
- **DPI** read/write, arbitrary values **100-26000** (not just the 5 marketing presets);
 written to onboard memory so it persists without the app.
- **Polling rate** read/write, 125 / 500 / 1000 Hz (the device's basic poll command set).
- **RGB lighting**, Static (any colour), Spectrum, Wave, Off (extended-matrix effects on
 the all-LEDs group).
- **LED brightness** 0-100%, discovered on hardware that brightness lives on the **LOGO LED
 (0x04)**, not the all-LEDs group like colours/effects.
- Settings write to the mouse's **onboard memory** (Synapse-equivalent persistence).

### Connection & status
- **Live battery polling** with an adaptive cadence (15 s connected / 4 s offline), so the
 menu bar updates automatically without clicking.
- **Instant USB plug/unplug detection** via IOKit service notifications, with polling as the
 fallback for the wireless-sleep case.
- **2-failure debounce** so transient wireless timeouts don't flap the UI to "offline".
- **Reconnect robustness**, ignores the transient garbage reading (0%/100%) the device
 emits right after reconnect until a real value is confirmed.
- **Connect/disconnect sounds** (Pop / Submarine).
- **Time-until-empty estimate**, local discharge-rate model with a **persisted learned rate**
 that survives restarts and recharges (immediate estimate instead of re-deriving for hours).

### Device detection (general)
- Detects **any** connected Razer mouse and shows its real model name (from the USB product
 string). Shows "No mouse connected" when none.
- Device registry flags models with a verified control protocol ("limited support" otherwise)
 and whether they have a battery, **battery-less wired mice hide all battery UI** and use a
 DPI read as the alive-check.

### Button remapping (software)
- Remap the side **Back/Forward** buttons via a `CGEvent` tap (the only OS-visible extra
 buttons; onboard remap isn't possible, OpenRazer lacks it and Razer's EULA forbids RE).
- Bindable actions: **keyboard shortcuts** (curated presets + a **custom recorder** for any
 combo), **mouse** (middle/double click), and **media keys** (play/pause, next, previous,
 volume, mute). Mappings persist.
- Available inline in the popover (swipe page) and in a standalone window.

### UI
- **Menu bar**: custom outlined mouse icon (adapts to light/dark, **dims when disconnected**)
 + battery % (toggleable; hidden for battery-less mice).
- **Right-click app menu**: status, Open Controls, Refresh, Configure Buttons, Input
 Monitoring Settings, Quit (mouse-dependent items disable when offline).
- **Control-Center-style popover** on a forced-dark background: per-section frosted cards,
 Razer-green accent, custom proportional battery gauge, persisted custom-DPI chip.
- **Inline page navigation** with push/pop slide: main ↔ colour wheel ↔ button config, at a
 fixed size, with scroll for overflow.
- **Inline hue/saturation colour wheel** + brightness, applied live (replaced the system
 colour panel).
- Live-config sections **grey out and disable when the mouse is disconnected** (battery stays
 readable).
- Popover **pre-warmed** at launch and opens instantly.

### Packaging & permissions
- SwiftPM executable: menu bar app with no args, **CLI diagnostics** with subcommands
 (`battery`/`dpi`/`poll`/`rgb`/`brightness`/`info`/render).
- `Scripts/build-app.sh` builds a `.app` bundle; `Scripts/setup-signing.sh` creates a stable
 self-signed identity so the **Input Monitoring / Accessibility grants persist across
 rebuilds**.
- Embedded official Razer logo (vector) in the header; everything clearly marked
 **unofficial / not affiliated with Razer**.

### Known limitations
- Only the two side buttons are remappable; other controls are handled onboard and invisible
 to macOS.
- Control protocol is verified only for the Cobra family; other Razer mice show name +
 battery but controls are unverified.
- Lighting's 4 marketing zones are driven as one group (not independently addressable in the
 protocol).
- Not notarized, distribution to others triggers a one-time Gatekeeper prompt.

### Not yet done / future
- GPL license + OpenRazer/Simple-Icons attribution file (the protocol is OpenRazer-derived;
 should ship GPL).
- Full Razer device-name table in the registry.
- Per-device command dialects for non-Cobra models.
- Optional app icon asset; connect-sound is a one-line constant to taste.
