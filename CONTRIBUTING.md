# Contributing

Thanks for helping! This is a community macOS control app for Razer mice. By contributing you
agree your contributions are licensed under **GPL-2.0** (the project license).

Start with **[docs/DOCUMENTATION.md](docs/DOCUMENTATION.md)**, it explains the architecture,
the HID protocol, and every feature.

## Build & run
```sh
swift run MacRazer # menu bar app (uses your Terminal's permission grants)
swift run MacRazer battery # CLI diagnostics: battery / dpi / poll / rgb / brightness / info
swift test # unit tests (protocol codec, battery models, persistence — no hardware needed)
./Scripts/build-app.sh # build a standalone .app
./Scripts/make-dmg.sh # package the .app into dist/MacRazer.dmg
./Scripts/release.sh 0.3.0 --dry-run # preview a release (see 'Cutting a release' below)
```
macOS 14+, Swift 6.1 / Xcode 16+. CI runs `swift build && swift test` on pushes to master
and on every PR; please run the tests locally before opening a PR, and add a test when you
fix logic in the pure layers (anything without live HID in it).

`make-dmg.sh` produces an unsigned/self-signed DMG (no paid Apple Developer ID), so it
triggers a Gatekeeper warning on first launch. That's expected; the README's Install section
has the bypass steps to link in release notes.

## Cutting a release

Use `./Scripts/release.sh <version>` rather than editing by hand. The version is recorded in
three places and the changelog in a fourth, and they have to agree: the in-app updater
compares the GitHub tag against the running bundle's own version, so a release tagged
`v0.3.0` whose bundle still says `0.2.1` leaves every user with an update badge they can
never clear. The script bumps all of them, promotes `## [Unreleased]` to a dated version
heading, builds both DMGs, and refuses outright if the version isn't newer, the tree is
dirty, you're not on an up-to-date master, or `[Unreleased]` is empty.

It stops before `git commit`, `git tag` and `gh release create`, printing them — review the
diff first. `Tests/Scripts/release-test.sh` covers the version comparison and both changelog
operations; CI runs it. Attach **both** DMGs to the release: the updater fetches the fixed
`MacRazer.dmg` name, and the versioned copy makes the Releases page self-describing.
`--dry-run` shows what it would do.

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
