# Contributing

Thanks for helping! This is a community macOS control app for Razer mice. By contributing you
agree your contributions are licensed under **GPL-2.0** (the project license).

Start with **[docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)**, it explains the architecture,
the HID protocol, and every feature.

## Build & run
```sh
swift run MacRazer # menu bar app (uses your Terminal's permission grants)
swift run MacRazer battery # CLI diagnostics: battery / dpi / poll / rgb / brightness / info
./Scripts/build-app.sh # build a standalone .app
./Scripts/make-dmg.sh # package the .app into dist/MacRazer.dmg for a release
```
macOS 14+, Swift 6.1 / Xcode 16+.

`make-dmg.sh` produces an unsigned/self-signed DMG (no paid Apple Developer ID), so it
triggers a Gatekeeper warning on first launch. That's expected; the README's Install section
has the bypass steps to link in release notes.

## The most valuable contribution: device profiles
Detection + name work for **any** Razer mouse already (via the USB product string). What's
verified is the **control protocol**, currently for the Cobra family + Atheris. To add your
mouse:

1. Plug it in and read its capabilities with the CLI:
 ```sh
 swift run MacRazer info # confirm it's detected, find the control interface
 swift run MacRazer battery
 swift run MacRazer dpi
 swift run MacRazer poll
 swift run MacRazer rgb static ff0000 # if it has lighting
 swift run MacRazer brightness
 ```
2. Note which commands succeed (`status=0x02`) and the values.
3. Add an entry to `RazerDevices.known` in
 [`Sources/MacRazer/RazerDevices.swift`](Sources/MacRazer/RazerDevices.swift) with the
 PID, name, `hasBattery`, `hasLighting`, and `maxDPI`. Set `fullySupported: true` **only
 after you've verified the controls on hardware**.
4. If a control misbehaves, the model likely uses a different command dialect (transaction
 id / command variant / LED id), check OpenRazer's `razermouse_driver.c` for that PID and
 open an issue/PR. We may need to parameterize `RazerCommands` per device.

Please include the model, PID, and which features you verified in your PR.

## Other contributions
Bug fixes, UI polish, and docs are all welcome. Keep new code in the style of the surrounding
files. Don't commit the built `*.app` or the cloned `reference/openrazer/` (both gitignored).
