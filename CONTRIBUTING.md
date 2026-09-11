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

### The release body

`release.sh` also drafts one, to `dist/RELEASE_NOTES-<version>.md`. **It is a draft, not the
finished copy** — it carries every changelog entry verbatim, and the changelog is written for
contributors. Expect to cut most of it; the published 0.3.0 body was about a fifth the length
of its changelog section.

The body matters more than it looks: the app fetches it and builds the popover's "What's new"
page from it, so a release published with no body makes that page quietly not appear. The
draft fills in the parts that are mechanical and easy to forget:

- every entry in the release, so none is left out by accident
- **everyone whose PR is in it**, by GitHub handle and PR number, read from the merge commits
- the Gatekeeper install note and the changelog link

A squash-merged PR leaves no merge commit to read, so its author can't be credited
automatically — the script says so on stderr and you add them by hand. Before publishing:

```sh
./Scripts/release-notes.sh --check dist/RELEASE_NOTES-<version>.md
```

which refuses a draft still carrying the `TODO:` placeholder or with no summary above its
first heading — either one would end up as the release's first paragraph, which is exactly
what the app shows.

## The most valuable contribution: device profiles
Detection and naming already work for **any** Razer mouse, via the USB product string. What
has to be verified per model is the **control protocol**. Four models have been checked on
real hardware so far; README's table says which, and what was run on each.

### 1. Run the probes and paste the output

Not a summary of the output. The raw text is what lets a reviewer see the status bytes and
the read-backs, and it is what earns a row in the README table.

```sh
swift run MacRazer info              # confirms detection and the PID it enumerates as
swift run MacRazer battery
swift run MacRazer dpi               # then: dpi 3200   (check the read-back matches)
swift run MacRazer poll              # then: poll 1000  (check the read-back matches)
swift run MacRazer rgb static ff0000 # if it has lighting
swift run MacRazer brightness        # sweeps LOGO / SCROLL / ZERO / BACKLIGHT
```

`status=0x02` is success. `0x03` is the mouse refusing, which is information, not failure —
several models legitimately refuse most LED groups.

**The `brightness` sweep is the one people skip, and it matters most.** Brightness lives on a
different LED group per model, and a wrong id does not error: the slider simply does nothing.
If a group other than `LOGO` is the one that answers, the entry needs `brightnessLed:` set to
it. The Basilisk V3 X answers only on `SCROLL_LED`, and that bug shipped unnoticed until
someone ran this sweep.

### 2. Get the protocol values from OpenRazer, not from another entry

Look your PID up in `reference/openrazer/driver/razermouse_driver.c` and
`daemon/openrazer_daemon/hardware/mouse.py`. Copying another model's values is the single
most common thing that needs fixing in review:

- **`transactionId` / `matrixTransactionId`** differ per model. Find your PID in the driver's
  switch statements. Class `0x0F` uses `matrixTransactionId`, everything else uses
  `transactionId`.
- **`transactionOverrides`** is only for commands whose id differs from your model's own
  class default. If the override sets the value the default already produces, leave it out.
  It defaults to empty, and empty is usually right.
- **`hasBattery`** means *the mouse reports a battery level*, not that it has one. The Orochi
  2013 runs on AA cells and reports nothing, so it is `false`. Check the model's method list
  in `mouse.py` for `get_battery`.
- **`maxDPI`** clamps the slider. If you have not actually set a DPI near the ceiling, say in
  the entry's comment that the figure is the vendor spec.

If hardware disagrees with the tables, **hardware wins** — say so in a comment so nobody
"corrects" it back later. The Atheris entry is the example: it uses `0x1f` where OpenRazer
specifies `0xFF`, with a comment saying why.

### 3. Set `fullySupported` honestly

It drives the popover's status line: `false` shows "Connected · limited support". Set it to
`true` only for a model whose controls you have actually exercised. A `false` entry with real
values is more useful than an optimistic `true` — the mouse is still detected, named, and its
controls still attempted.

Partial verification is welcome. "DPI works, could not test the rest" is a perfectly good PR.

### 4. If a control misbehaves

The model probably uses a different command dialect (transaction id, command variant, LED id).
Check OpenRazer for that PID and open an issue or PR; we may need to parameterize
`RazerCommands` further, as we did for `brightnessLed`.

Include the model, PID, and the probe output in your PR. Add a test to
`RazerDevicesTests.swift` for anything model-specific you introduce.

## Other contributions
Bug fixes, UI polish, and docs are all welcome. Keep new code in the style of the surrounding
files. Don't commit the built `*.app` or the cloned `reference/openrazer/` (both gitignored).
