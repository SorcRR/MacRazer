# Changelog

All notable changes to this project. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). The project is **pre-release** (0.x) —
expect rough edges until 1.0.

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
