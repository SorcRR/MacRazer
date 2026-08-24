# Changelog

All notable changes to this project. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). The project is **pre-release** (0.x) —
expect rough edges until 1.0.

## [Unreleased]

### Added
- **The menu bar icon shows a lightning bolt while the mouse is charging**, in place of the
 mouse's button-split line — the same at-a-glance cue macOS gives for its own battery, so
 you don't have to open the popover to tell. The body silhouette is unchanged, so only the
 detail inside it swaps.
- **A system notification fires once the mouse's battery drops below 15%** (the same
 threshold the battery card already colors red), so you don't have to open the popover to
 notice. One alert per discharge: it re-arms when the mouse is charging or the charge
 climbs back to 20%+, so neither the 15s poll cadence nor a one-off garbage reading can
 repeat it. Swapping to a second mouse re-arms it for that unit, and charging back up
 withdraws the banner instead of leaving it in Notification Center. The armed state lives
 in memory, so a relaunch while the mouse is still low can alert once more. If notifications
 are switched off for MacRazer the alert stays pending rather than being silently spent, so
 turning them on mid-discharge still gets you the warning.
- **The usage chart now shows ~2 charges: the previous charge stays visible (dimmed) behind
 the current one.** Recharging no longer blanks the chart back to "Gathering data…" — the
 finished cycle's raw curve is kept (and persisted per device) and drawn as a dimmed gray
 line behind the live one, with a gap where the charge happened. While docked, the chart
 keeps showing the previous charge with a "Charging — tracking paused" note instead of
 disappearing entirely. Hover works across both curves. Noise blips (a brief unplug/re-dock,
 same thresholds as the "Past charges" log) don't replace the kept curve.

### Fixed
- **The CLI diagnostics (`battery`, `dpi`, `poll`, `stages`, `rgb`, `brightness`) now explain
 a missing Input Monitoring grant instead of printing a bare `IOHIDDeviceOpen failed:
 0xe00002e2`.** The GUI already had this guidance (`PopoverView`/`PermissionsModel`); no CLI
 path checked for it. The hint distinguishes the two cases that actually differ: under
 `swift run` the grant belongs to the *terminal*, not the SwiftPM binary. The `battery`
 command also no longer blames the wireless dongle for what is a permissions failure.
- **`VersionCompare` no longer reports a downgrade as an update.** Unparseable version
 components were dropped rather than read as 0, which shifted the remaining ones left — so
 `"v0.1.0"` parsed as `[1, 0]` and compared newer than `"0.2.0"`. `UpdateChecker` strips a
 bare leading `v`, so this needed a differently-shaped tag to bite, but the comparison was
 wrong regardless.
- **A Mac sleep no longer resets the battery-usage chart.** After hours of rest a Li-ion
 cell legitimately reads a few percent *higher* on wake (voltage recovery, no charger
 involved), and any uptick of 2+ points was treated as "the mouse got recharged" — wiping
 the whole discharge cycle, so the chart restarted at the sleep/wake boundary. Upticks now
 confirm on two consecutive readings before resetting (a one-off garbage read around the
 sleep transition is discarded instead of acted on), and after an offline gap an uptick has
 to reach 10 points before it counts as a recharge — below that it's read as recovery and
 the cycle continues. Trade-off: a genuine but tiny top-up (<10 points) during a gap is no
 longer detected as a cycle boundary; it shows as an uptick within the ongoing cycle.

## [0.2.0] — 2026-07-02

### Added
- **Learned discharge curve for the Razer Cobra HyperSpeed.** Rather than one flat %/hour rate,
 the app now learns how long the battery actually dwells at each percent (0-100) from real
 discharge history, specifically for the Cobra HyperSpeed (wired + wireless) — its Li-ion cell
 has a long flat voltage plateau through most of the discharge and steep drops near full/empty,
 which a single linear rate can't represent. The learned curve is shared across every Cobra
 HyperSpeed unit the app sees (not per physical mouse) so it improves faster, and falls back to
 the existing linear-rate estimate for any percent it doesn't have data for yet — with zero
 data the estimate is identical to before. Every other mouse model is unaffected and keeps
 using the generic estimate, since their cell/firmware behavior is unverified.
- **Usage graph now covers the whole charge, not just the last ~2 hours.** The retained sample
 window was raised from 500 to 25,000 (~104 hours), and the discharge curve on the usage page
 is now colored green/orange/red at the same thresholds as the main battery bar, instead of a
 flat color.

### Changed (profiles)
- **Profiles now capture and restore the onboard DPI stage table** — the presets the
 mouse's own DPI button cycles through, which a profile previously didn't touch (it saved
 only the single current DPI). Applying a profile writes the stages (marking the one
 matching the profile's DPI as active), then the exact DPI. Profiles saved by older
 versions keep working and simply don't touch the stage table. A `stages` CLI diagnostic
 reads/writes the table (`swift run MacRazer stages 400,800,1600 0`); the write was
 verified on Cobra HyperSpeed hardware.
- **A serial number that resolves late no longer strands that session's data.** If the
 serial probe fails on the session's first connect, per-device data (battery history,
 charge cycles, learned rate, profiles, button mappings, custom DPI) lands under a PID
 fallback key; when the serial then resolves in the same session, that data is now migrated
 to the serial key instead of being orphaned forever. Profiles are *merged* (a profile
 saved before the serial resolved survives even when the serial key already has its own);
 the other stores fill holes only and never overwrite existing serial-keyed data.
 Cross-session orphans are deliberately left alone — with two same-model mice they could
 belong to the other unit.
- **The Profiles card moved below Configure Buttons** — the page now reads top-down as "here
 are the controls, here's how to save and recall them as presets".
- **Applying a profile is all-or-nothing and says so when it fails.** Button remaps and the
 active checkmark now land only when the mouse took the whole config; a failed apply changes
 nothing and shows "Couldn't apply — the mouse isn't responding" (previously it silently
 half-applied: remaps were overwritten first, some values landed, and the *previous*
 profile's checkmark survived over the hybrid).
- **The active checkmark now clears when the mouse's own controls change the config** (e.g.
 the on-mouse DPI-cycle button) or when the config drifted while the app was closed — it
 only stays lit while the live settings actually match the profile.
- **Lighting state (effect + colour) is now app-tracked ground truth**, published only on
 successful device writes — the picker can't claim lighting the mouse never took, and "+"
 can't snapshot it into a profile.
- **Profiles page works honestly offline:** rename and delete now work (they're app-side),
 applying is disabled with a note, and the popover no longer reopens onto a stale sub-page.
- **The chips row wraps** instead of overflowing the popover with several profiles; whole
 rows (not a 20pt circle) apply on the manage page; Esc cancels a rename; default names
 skip already-used numbers; "+" is disabled until the mouse's settings have actually been
 read (a too-early snapshot saved 0 DPI, which later applied as 100); profiles saved for
 lighting-less mice no longer claim a lighting mode in their summary.

### Fixed
- **Wired-only mice no longer show a "2.4 GHz" connection chip** (reported on a Basilisk V3).
 The chip was guessed from a `charging ⇒ wired` heuristic, and a wired mouse never reports
 charging. The connection kind now comes from the device registry (a PID identifies the
 link — wireless models enumerate under a different PID when cabled); unknown models show a
 neutral "USB" chip, which is true for both a cable and a dongle.
- **The button-remap shortcut menu no longer collapses while you're choosing** (reported on
 a Basilisk V3, but affected every mouse). Two causes: the battery poll and the popover's
 2s settings refresh re-assigned unchanged `@Published` values, and every no-op publish
 re-rendered the observing views — dismissing any open SwiftUI menu; published state now
 only fires on actual changes and the app-level subscriptions deduplicate. And on battery
 mice, *real* changes (a new battery sample every ~15s while discharging) had the same
 effect — the remap page is now isolated from the controller's re-renders entirely, since
 it only depends on the remapper.
- **Razer Basilisk V3 added to the device registry** (wired-only, no battery UI, 11-zone
 lighting, 26K DPI, per-command transaction ids matching OpenRazer — it splits the
 DPI-stages commands from everything else). Previously it fell back to unknown-device
 defaults, which also meant a bogus battery section and a permanent 4-second fast-poll loop.
- **A Razer keyboard (or second Razer device) can no longer capture the app.** Device
 matching is vendor-wide, and the app used to bind whichever single interface scored
 highest — with a Razer keyboard attached it could open the keyboard and send mouse
 commands to it. Devices are now ranked first (registry-known mice, then devices exposing
 a Mouse interface), which of two identical mice wins is stable across reconnects, and
 unplugging a *different* Razer product no longer bypasses the offline debounce (which
 could flap the mouse to "offline" with a disconnect sound on a coincidental wireless
 timeout).
- **Device responses are now validated before being trusted.** A reply that doesn't echo the
 command it answers (a stale buffer from the previous command, or an all-zeros "not ready"
 report), a short transfer, or an explicit failure/not-supported status was previously
 parsed as real data — a flaky wireless read could publish another command's bytes as the
 DPI or brightness, and even persist them into a profile. Such replies are now re-read or
 surfaced as errors, matching the OpenRazer reference behavior.
- **Settings reads are independent of each other.** One transient failure (or a model that
 genuinely lacks brightness, like the Atheris) no longer throws away DPI/polling values that
 were already read — on-mouse DPI-button changes reflect reliably now.
- **Setting DPI/polling/brightness/lighting only updates the UI when the device write
 actually succeeded**, instead of optimistically showing a value the mouse never accepted;
 on a failed write the sliders snap back to the real values. Applying a profile now sends
 the whole config directly and marks the profile active only when the device took all of
 it — applying to a sleeping mouse no longer highlights a profile that never landed.
- **Offline detection and quit are snappier:** the retry ladder no longer sleeps after its
 final attempt, "not supported" replies aren't pointlessly retried, and the refresh
 spinner's cosmetic delay no longer blocks the device-command queue.
- **Button mappings no longer leak from one mouse to another.** Connecting a mouse with no
 saved mappings kept the previous mouse's table live — remapping the new mouse with the old
 one's bindings, and saving the old table under the new device's key on the next edit.
 Remapping now also pauses whenever the mouse is offline (powered off, asleep, dongle
 unplugged) — previously the mappings kept firing for matching buttons on other pointing
 devices, since macOS can't tell which mouse sent a click. The remap page shows a note while
 paused and states the any-device limitation; stale mappings persisted under the old
 no-device key by earlier builds are cleaned up.
- **Pressing Escape in the shortcut recorder now cancels it** instead of binding the mouse
 button to ⎋ (modifier combos with Escape still record).
- **Buttons remapped to a mouse click now synthesize a real click count**, so apps reading
 `clickCount` (e.g. middle-click-closes-tab) recognize them.
- **A failed update check no longer silences update notices for a day** — only successful
 checks count against the daily throttle, so an offline launch retries at the next
 opportunity. A found update is also remembered across relaunches instead of vanishing until
 the next day's check.
- **"Quit & Relaunch" no longer just quits when the relaunch fails** — it only terminates
 once the replacement instance actually launched, and says so if it couldn't (e.g. when
 running straight from the mounted DMG).
- **Navigating to a sub-page no longer lets the popover resize after the transition** — the
 measured main-page height is kept while the main page is unmounted.
- **A custom DPI saved before the device key resolves is no longer written to a shared
 "default" slot** that every mouse would read.
- **Renaming a profile to an empty/whitespace name is now rejected**, matching profile
 creation.
- **Chart tooltips now respect the system's 12/24-hour locale setting** and include the day,
 since a discharge cycle can span several days.
- **The learned discharge curve now measures real dwell time per percent.** It was averaging
 per poll tick instead of per completed traversal, so after one full discharge every percent
 "learned" a dwell of ~15 seconds and the estimate collapsed toward `percent × 15s` (e.g.
 "~20m left" at 80% on a ~30h battery). Buckets now accumulate an open dwell and commit it
 only when the discharge actually drops out of that percent; partial dwells (charge started
 mid-percent, offline gaps) are discarded instead of polluting the mean. Previously learned
 curve data was corrupt under the old math and is discarded on upgrade — the curve re-learns
 from the next discharge cycle.
- **Idle/offline gaps no longer distort the discharge-rate estimate.** The session rate fit
 spanned raw wall-clock time, so a weekend with the mouse switched off could turn a 1%/hour
 mouse into "~19d left" on Monday — and blend that bogus rate into the persisted learned
 rate. Gaps longer than 5 minutes are now spliced out of the fit entirely (neither the gap's
 time nor the percent self-drained during it counts), making the estimate mean "time
 remaining at active use", consistent with the dwell-based curve model.
- **Battery/cycle/curve files are now written atomically, with a format version.** A crash or
 power loss mid-write could truncate the JSON, and the next launch would silently start from
 empty and overwrite what was left — permanently losing that device's history. Existing
 history files are migrated in place.
- **The usage chart no longer renders every raw sample.** A full multi-day cycle is up to
 25,000 samples, re-rendered on every 15s poll while the usage page was open (plus a full
 scan per mouse-move for the hover readout) — enough to stall the popover. The published
 snapshot is now decimated to ~600 min/max-preserving points; persistence still keeps every
 sample.
- **A clean quit no longer drops the last ~30 seconds of history.** The throttled savers are
 flushed on app termination.
- **Docking the mouse no longer leaks one charging sample into the discharge history.** The
 first (unconfirmed) charging report is skipped instead of being logged as a discharge
 sample, and the history file is no longer rewritten every poll tick during a charge session.
- **A multi-hour disconnect or sleep gap no longer gets learned as real per-percent dwell
 time.** The discharge-curve model could mistake "mouse was offline for hours" for "battery
 sat at this percent for hours," skewing its estimate after as few as two such gaps; intervals
 longer than 5 minutes are now excluded from what it learns from.

### Changed
- Persisting battery/discharge-curve history to disk is now throttled (~every 30s, plus
 immediately on a charge-cycle boundary) instead of on every poll tick, now that the larger
 sample window would otherwise mean rewriting a much bigger file every 4-15 seconds.
- **The device registry is the single source of per-model data.** The protocol transaction
 id (previously hardcoded to the Cobra family's 0x1f for every mouse) and the menu-bar
 silhouette now live in `RazerDevices` and are picked per connected model — adding a mouse
 is one row instead of edits across the transport, commands, and drawing code. The plain
 Razer Cobra now follows OpenRazer's per-command split (0xFF for DPI/polling/serial, 0x1f
 for lighting); hardware-verified models keep their verified ids everywhere.

### Internal
- **The battery poll's decision logic is a tested pure state machine.** The offline
 debounce, post-reconnect garbage rejection, and charging two-poll confirmation moved out
 of `MouseController` into `BatteryPollStateMachine` — a value type with no I/O — with
 tests replaying poll sequences (reconnect garbage, debounce, charge blips, device swaps).
 Behavior is unchanged; it's now verifiable without hardware.
- **Unit tests + CI.** The pure layers — protocol codec (CRC/serialization), command
 builders/parsers, the discharge-curve and rate-fit math, charge-cycle detection, and the
 versioned persistence — now have a test suite (`swift test`, no hardware needed), including
 regression tests for the estimate bugs fixed in this release. GitHub Actions runs
 build+tests on pushes to master and on every PR. The data stores take an injectable
 directory/defaults so tests never touch real user data.

## [0.1.5] — 2026-06-29

### Added
- **Update check.** The app checks GitHub once a day for a newer release and shows a card in
 the popover (plus a badge dot on the menu bar icon) when one is available, with a one-click
 "Download" that fetches the new DMG and opens it in Finder.
- **Hover tooltips on the battery-usage charts.** Hovering the discharge curve or a past-charge
 bar shows its value/time next to the section title.

### Changed
- "Time since last full charge" is now **"Time since last charge"**, and shows the percentage
 the cycle started from (e.g. "1d 4h (from 73%)") — the cycle boundary isn't necessarily a
 full 100% charge, so the old label was misleading for partial top-ups.

### Fixed
- **A one-off garbage charging-status read right after sleep/wake (or a reconnect) no longer
 wipes the whole discharge history.** A not-charging→charging transition now has to be
 confirmed on two consecutive polls before it's trusted, since acting on a single bad read
 destructively reset the "time since last charge" timer to ~0.

## [0.1.4] — 2026-06-27

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
