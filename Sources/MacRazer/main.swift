// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

// Entry point. No arguments launches the menu bar app; subcommands are CLI diagnostics
// against real hardware (battery / dpi / poll / rgb / brightness / info) plus render-*
// commands that draw UI pages and icons to PNGs for visual inspection without a device.
// Battery reads may time out over the wireless dongle — the known issue from
// openrazer/openrazer#2583.

import AppKit
import ServiceManagement
import SwiftUI

let args = Array(CommandLine.arguments.dropFirst())

// No arguments → launch the menu bar app. Subcommands → run the CLI diagnostics below.
if args.isEmpty {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
    exit(0)
}

let command = args.first!

/// Turn a permission-denied failure into the fix, instead of leaving a bare hex code on
/// screen. The GUI already does this (PopoverView / PermissionsModel); every CLI catch
/// routes through here so it does too. Returns whether the error was a permission problem,
/// so callers can suppress advice that would then be misleading.
@discardableResult
func printPermissionHintIfDenied(_ error: Error) -> Bool {
    guard HIDDevice.errorLooksPermissionDenied(String(describing: error)) else { return false }
    print("  → macOS is refusing HID access (Input Monitoring).")
    print("    Running via `swift run MacRazer …`? The grant belongs to the terminal that")
    print("    launched it, not to the SwiftPM binary — grant Terminal (or iTerm/your IDE) in")
    print("    System Settings › Privacy & Security › Input Monitoring, then start a new")
    print("    terminal session and retry.")
    print("    Running MacRazer.app? Grant MacRazer itself there, then relaunch it — macOS")
    print("    only applies the grant to a freshly-launched app.")
    return true
}

func openDevice() -> HIDDevice? {
    do {
        let dev = try HIDDevice.open(vendorId: Razer.vendorId)
        print("✓ Opened \(dev.productName) (VID 0x1532, PID 0x\(String(format: "%04x", dev.productID)))")
        return dev
    } catch {
        print("✗ \(error)")
        printPermissionHintIfDenied(error)
        return nil
    }
}

/// Shared by the render-* commands: draw a SwiftUI view at 2x on the app's dark backdrop
/// and write it to a PNG.
@MainActor func writeViewPNG<V: View>(_ view: V, to path: String) {
    // Force dark, because every surface these previews stand in for does: the popover sets
    // `.darkAqua`, and so do the Settings, Permissions and About windows. Without it
    // `.secondary`/`.tertiary` resolve for light mode and render as near-black text on the
    // dark backdrop below — which made every preview look like it had a contrast bug it
    // doesn't have.
    let renderer = ImageRenderer(
        content: view.environment(\.colorScheme, .dark).padding(1).background(Color(white: 0.13)))
    renderer.scale = 2
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } else {
        print("Render failed")
    }
}

/// Renders through a real `NSHostingView` instead of `ImageRenderer`.
///
/// `ImageRenderer` draws a `ScrollView` as an empty box — its content is laid out lazily and
/// never makes it into the snapshot — so a page whose body is a scroll view has to be hosted
/// in a view hierarchy and captured from there. Fixed size, because a hosting view has no
/// window to size it.
@MainActor func writeHostedPNG<V: View>(_ view: V, size: CGSize, to path: String) {
    // The popover's own backdrop. `cacheDisplay` captures no window background, and the dark
    // scheme's primary text is white — without this the whole page renders white on white.
    let hosted = view.environment(\.colorScheme, .dark).background(Color(white: 0.13))
    let host = NSHostingView(rootView: AnyView(hosted))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        print("Render failed")
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("Render failed")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

/// The output path for a `render-*` command: the first argument that names a PNG.
///
/// Flags are bare words and the path is positional, so "the first argument" wrote a file
/// literally named `update` or `charging`. Keeping a list of known flags per command only
/// moves the bug — a flag added later and forgotten in the list becomes the filename again.
/// Asking what the argument *is* needs no list to keep in sync.
func outputPath(_ args: ArraySlice<String>, default fallback: String) -> String {
    args.first { $0.lowercased().hasSuffix(".png") } ?? fallback
}

switch command {
case "info":
    // List every HID interface the dongle exposes, so we can see which one is the control
    // interface (vendor usage page / largest feature report).
    let devices = HIDDevice.matchingDevices(vendorId: Razer.vendorId)
    if devices.isEmpty {
        print("No Razer devices found (VID 0x1532).")
        exit(1)
    }
    print("Found \(devices.count) HID interface(s) for VID 0x1532:")
    for (i, dev) in devices.enumerated() {
        print("  [\(i)] \(HIDDevice.describe(dev))")
    }

case "login-item":
    // Report on (and optionally flip) the "Start MacRazer at login" registration — the one
    // piece of app state that lives in the system rather than in our own defaults, so it can't
    // be checked by reading a file. `on`/`off` drive the same `LaunchAtLogin.setEnabled` the
    // popover switch calls, which also makes this the repair path when the GUI isn't reachable.
    // Only meaningful from the packaged .app: under `swift run` there is no bundle to register.
    let loginItem = LaunchAtLogin()
    if let arg = args.dropFirst().first {
        switch arg {
        case "on": loginItem.setEnabled(true)
        case "off": loginItem.setEnabled(false)
        default:
            print("Usage: login-item [on|off]")
            exit(64)
        }
        if let failure = loginItem.lastError { print("⚠︎ \(failure)") }
    }
    print("Bundle:   \(Bundle.main.bundleURL.path)")
    print("Eligible: \(loginItem.isSupported ? "yes" : "no — not an installed .app (see AppLocation)")")
    let status = SMAppService.mainApp.status
    let described: String
    switch status {
    case .enabled: described = "enabled — macOS will start MacRazer at login"
    case .notRegistered: described = "not registered — the switch is off"
    case .requiresApproval: described = "requires approval in System Settings › General › Login Items"
    case .notFound: described = "not found — macOS has no record of this bundle"
    @unknown default: described = "unknown (raw \(status.rawValue))"
    }
    print("Status:   \(described)")
    print("Default applied once: \(UserDefaults.standard.bool(forKey: "launchAtLoginDefaultApplied"))")

case "render-ui":
    // Render the popover to a PNG for static visual inspection (no device needed).
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "ui-preview.png")
    let controller = MouseController()
    controller.loadPreviewState()
    if args.contains("offline") { controller.setPreviewOffline() }
    if args.contains("bluetooth") { controller.setPreviewBluetooth() }
    let updateChecker = UpdateChecker()
    if args.contains("update") { updateChecker.loadPreviewState(notes: PreviewNotes.releaseBody) }
    if args.contains("updated") { updateChecker.loadPreviewUpdated(notes: PreviewNotes.releaseBody) }
    if args.contains("downloading") { updateChecker.loadPreviewState(phase: .downloading(0.42)) }
    let launchAtLogin = LaunchAtLogin()
    launchAtLogin.loadPreviewState()
    // The notes page is its own render: it is a scroll view, so it needs the hosted path,
    // and it is sized to the height the main page renders at — the whole point of checking
    // it is whether the notes fit there.
    if args.contains("whatsnew") {
        // `installed` is the same page reached from the "Updated to …" card: same notes, no
        // button, because there is nothing left to install.
        let installed = args.contains("installed")
        if installed {
            updateChecker.loadPreviewUpdated(notes: PreviewNotes.releaseBody)
        } else {
            updateChecker.loadPreviewState(notes: PreviewNotes.releaseBody)
        }
        writeHostedPNG(WhatsNewPage(version: updateChecker.latestVersion ?? AppInfo.displayVersion,
                                    notes: (installed ? updateChecker.installedNotes : updateChecker.latestNotes)
                                        ?? ReleaseNotes.parse(PreviewNotes.releaseBody),
                                    canInstallInPlace: updateChecker.canInstallInPlace,
                                    onBack: {}, onUpdate: installed ? nil : {}),
                       size: CGSize(width: 320, height: 748), to: path)
        break
    }
    let rootView: AnyView = args.contains("color")
        ? AnyView(ColorPickerPage(color: .constant(.blue), onBack: {}, onApply: { _ in }))
        : args.contains("usage")
        ? AnyView(UsageGraphView(controller: controller, onBack: {}))
        : args.contains("profiles")
        ? AnyView(ProfilesView(controller: controller, remapper: ButtonRemapper(), onBack: {}))
        : AnyView(PopoverView(controller: controller, remapper: ButtonRemapper(), updateChecker: updateChecker,
                              launchAtLogin: launchAtLogin, onOpenSettings: {})) // no windows in a render
    writeViewPNG(rootView, to: path)

case "render-settings":
    _ = NSApplication.shared
    let settingsPath = outputPath(args.dropFirst(), default: "settings-preview.png")
    let sc = MouseController()
    sc.loadPreviewState()
    let sl = LaunchAtLogin()
    sl.loadPreviewState()
    let su = UpdateChecker()
    // `update` shows the Updates section in its available state, which is the only way to see
    // the Install Now button without waiting for a real release.
    if args.contains("update") { su.loadPreviewState() }
    writeViewPNG(SettingsView(controller: sc, launchAtLogin: sl, updateChecker: su, onDone: {}),
                 to: settingsPath)

case "render-about":
    _ = NSApplication.shared
    let aboutPath = outputPath(args.dropFirst(), default: "about-preview.png")
    // `notes` shows the "What's new in …" row, which is otherwise only there once the app has
    // cached a release body.
    writeViewPNG(AboutView(onDone: {}, // no window to close in a render
                           notes: args.contains("notes") ? ReleaseNotes.parse(PreviewNotes.releaseBody) : nil),
                 to: aboutPath)

case "render-remap":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "remap-preview.png")
    let r = ButtonRemapper()
    r.loadPreviewState()
    writeViewPNG(RemapView(remapper: r), to: path)

case "render-permissions":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "permissions-preview.png")
    let controller = MouseController()
    controller.loadPreviewState()
    let model = PermissionsModel()
    model.loadPreviewState()
    writeViewPNG(PermissionsView(model: model, controller: controller), to: path)

case "icon":
    // Render the menu bar mark to a PNG for visual inspection.
    let iconArgs = args.dropFirst()
    let path = outputPath(iconArgs, default: "icon-preview.png")
    // Optional size, so the mark can be checked at real menu bar scale (~21pt @2x) rather
    // than judged from a downsampled 256px render. Bounded: an unbounded value makes the
    // bitmap allocation fail and the write silently do nothing.
    let size = iconArgs.compactMap { Int($0) }.first { $0 > 0 }.map { CGFloat(min($0, 2048)) } ?? 256
    // `nologo` matches the menu bar's own call (razerCutout: false) so what's previewed is
    // what ships there.
    guard MenuBarIcon.writePreview(to: path, size: size, razerCutout: !iconArgs.contains("nologo"),
                                   charging: iconArgs.contains("charging"),
                                   lightMenuBar: iconArgs.contains("light")) else {
        print("Render failed")
        exit(1)
    }
    print("Wrote \(path)")

case "icon-models":
    // Render each per-model silhouette (header icon variants) to PNGs for visual inspection.
    let dir = args.dropFirst().first ?? "/tmp"
    let shapes: [(String, RazerMouseSilhouette, Bool)] = [
        ("cobra", .cobra, true), ("cobra-pro", .cobraPro, true), ("atheris", .atheris, false),
    ]
    for (name, shape, lighting) in shapes {
        let p = "\(dir)/macrazer-model-\(name).png"
        MenuBarIcon.writePreview(to: p, size: 256, silhouette: shape, razerCutout: lighting)
        print("Wrote \(p)")
    }

case "appicon":
    // Render app-icon concepts (original mouse mark, no Razer triskelion).
    let dir = args.dropFirst().first ?? "/tmp"
    let green = NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1)
    let greenBright = NSColor(red: 0.42, green: 1.0, blue: 0.25, alpha: 1)
    let dark = NSColor(white: 0.09, alpha: 1)
    let concepts: [(String, NSColor, NSColor)] = [
        ("concept1-dark-green", dark, greenBright),
        ("concept2-green-dark", green, dark),
        ("concept3-dark-white", NSColor(white: 0.13, alpha: 1), .white),
    ]
    for (name, bg, mark) in concepts {
        let p = "\(dir)/macrazer-\(name).png"
        MenuBarIcon.writeAppIcon(to: p, size: 512, bg: bg, mark: mark)
        print("Wrote \(p)")
    }

case "iconset":
    // Render the chosen app icon (dark + green) at all .iconset sizes for iconutil.
    let dir = args.dropFirst().first ?? "/tmp/MacRazer.iconset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let bg = NSColor(white: 0.09, alpha: 1)
    let mark = NSColor(red: 0.42, green: 1.0, blue: 0.25, alpha: 1)
    let sizes: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
        ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, sz) in sizes {
        MenuBarIcon.writeAppIcon(to: "\(dir)/\(name).png", size: sz, bg: bg, mark: mark)
    }
    print("Wrote iconset to \(dir)")

case "battery":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let resp = try dev.sendWithRetry(RazerCommands.getBatteryLevel())
        // arguments[1] holds the 0-255 level (arguments[0] is typically the var-store echo).
        let raw = resp.arguments[1]
        let pct = RazerCommands.batteryPercent(fromRaw: raw)
        print("Battery: \(pct)%  (raw byte = \(raw), status = 0x\(String(resp.status, radix: 16)))")
        print("Full response args[0..8]: \(resp.arguments[0..<9].map { String(format: "%02x", $0) }.joined(separator: " "))")
    } catch {
        print("Battery read failed: \(error)")
        // Only blame the dongle when it isn't a permission problem — sending someone to
        // re-seat hardware over a TCC denial wastes their time.
        if !printPermissionHintIfDenied(error) {
            print("(This is the documented wireless-dongle timeout. Try: re-seat the dongle, ")
            print(" move the mouse to wake it, or test over wired USB-C to compare.)")
        }
        exit(2)
    }

case "dpi":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        // Read current DPI first.
        let before = RazerCommands.parseDPI(try dev.sendWithRetry(RazerCommands.getDPI()))
        print("Current DPI: x=\(before.x) y=\(before.y)")

        // If a value was given, set it and read back to confirm it persisted.
        if let arg = args.dropFirst().first, let x = UInt16(arg) {
            let y = args.dropFirst(2).first.flatMap { UInt16($0) } ?? x
            print("Setting DPI to x=\(x) y=\(y) …")
            let resp = try dev.sendWithRetry(RazerCommands.setDPI(x: x, y: y))
            print("  set status = 0x\(String(resp.status, radix: 16))")
            let after = RazerCommands.parseDPI(try dev.sendWithRetry(RazerCommands.getDPI()))
            print("Read-back DPI: x=\(after.x) y=\(after.y)")
            if after.x == x && after.y == y {
                print("✓ DPI write confirmed (persisted to onboard memory)")
            } else {
                print("⚠︎ Read-back doesn't match requested value — investigate.")
            }
        } else {
            print("(pass a value to set, e.g. `dpi 3200` or `dpi 1600 1600`)")
        }
    } catch {
        print("DPI command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "stages":
    // Read (and optionally write) the onboard DPI stage table the mouse's DPI button cycles.
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let before = try dev.sendWithRetry(RazerCommands.getDPIStages())
        print("Current stages: \(RazerCommands.parseDPIStages(before)) (active byte = \(RazerCommands.parseActiveDPIStage(before)))")
        if let arg = args.dropFirst().first {
            let tokens = arg.split(separator: ",")
            let stages = tokens.compactMap { Int($0) }
            // Reject the whole argument on any junk token — silently dropping "3200o"
            // would shrink the onboard table the DPI button cycles.
            guard !stages.isEmpty, stages.count == tokens.count,
                  stages.count <= RazerCommands.maxDPIStages else {
                print("Usage: stages 400,800,1600[,…]   (1-\(RazerCommands.maxDPIStages) comma-separated numbers)")
                exit(64)
            }
            let active = args.dropFirst(2).first.flatMap { Int($0) } ?? 0
            print("Setting stages \(stages) (active \(active)) …")
            let resp = try dev.sendWithRetry(RazerCommands.setDPIStages(stages, activeStage: active))
            print("  set status = 0x\(String(resp.status, radix: 16))")
            let after = try dev.sendWithRetry(RazerCommands.getDPIStages())
            print("Read-back: \(RazerCommands.parseDPIStages(after)) (active byte = \(RazerCommands.parseActiveDPIStage(after)))")
        } else {
            print("(pass values to set, e.g. `stages 400,800,1600 1` — last number is the active stage index)")
        }
    } catch {
        print("Stages command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "poll":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let before = RazerCommands.parsePollingRate(try dev.sendWithRetry(RazerCommands.getPollingRate()))
        print("Current polling rate: \(before)Hz")
        if let arg = args.dropFirst().first, let hz = Int(arg) {
            guard RazerCommands.supportedPollingRates.contains(hz) else {
                print("Unsupported rate. Choose one of: \(RazerCommands.supportedPollingRates.map { "\($0)" }.joined(separator: ", "))Hz")
                exit(64)
            }
            print("Setting polling rate to \(hz)Hz …")
            let resp = try dev.sendWithRetry(RazerCommands.setPollingRate(hz))
            print("  set status = 0x\(String(resp.status, radix: 16))")
            let after = RazerCommands.parsePollingRate(try dev.sendWithRetry(RazerCommands.getPollingRate()))
            print("Read-back: \(after)Hz")
            print(after == hz ? "✓ Polling rate write confirmed" : "⚠︎ Read-back doesn't match.")
        } else {
            print("(pass a value to set: \(RazerCommands.supportedPollingRates.map { "\($0)" }.joined(separator: "/"))Hz, e.g. `poll 1000`)")
        }
    } catch {
        print("Poll-rate command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "brightness":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    func dump(_ r: RazerReport) -> String {
        "status=0x\(String(r.status, radix: 16)) args[0..5]=" + r.arguments[0..<6].map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    do {
        // Probe every LED group, LOGO first. A refusal on any one of them — including
        // LOGO — is expected on some models (the Basilisk V3 X HyperSpeed lights only its
        // scroll wheel and answers 0x03 for LOGO), so this must not abort the sweep: the
        // whole point is to discover which LEDs answer on a model we don't know yet.
        for (name, led) in [("LOGO", Razer.logoLed), ("SCROLL", Razer.scrollLed),
                            ("ZERO", Razer.zeroLed), ("BACKLIGHT", Razer.backlightLed)] {
            do {
                // `send`, not `sendWithRetry`: a FAILURE (0x03) for a given model and LED is
                // deterministic — the same answer three times, 150ms apart. Retrying it turns
                // a four-group sweep on a model where three refuse into nine round trips and
                // most of a second of pure backoff, in a diagnostic whose whole job is to
                // report which group answered.
                let rr = try dev.send(RazerCommands.getBrightness(led: led))
                print("GET brightness (led \(name)=0x\(String(format: "%02x", led))): \(dump(rr))"
                      + " → \(RazerCommands.brightnessPercent(fromRaw: rr.arguments[2]))%")
            } catch {
                print("GET brightness (led \(name)=0x\(String(format: "%02x", led))): refused — \(error)")
            }
        }
        if let arg = args.dropFirst().first, let pct = Int(arg) {
            let led = RazerDevices.brightnessLed(pid: dev.productID)
            // Deliberately outside the sweep's per-LED catch: a refusal here is a real
            // failure to report, not a group that simply doesn't answer.
            let raw = RazerCommands.brightnessRaw(fromPercent: pct)
            print("SET brightness \(pct)% (raw \(raw)) on led 0x\(String(format: "%02x", led)) …")
            let sr = try dev.sendWithRetry(RazerCommands.setBrightness(raw, led: led))
            print("  set: \(dump(sr))")
            let back = try dev.sendWithRetry(RazerCommands.getBrightness(led: led))
            print("  read-back: \(dump(back)) → \(RazerCommands.brightnessPercent(fromRaw: back.arguments[2]))%")
        }
    } catch {
        // The sweep above handles its own refusals per LED, so only the optional write can
        // reach this — saying "probe failed" would point at the part that just succeeded.
        print("Brightness write failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "rgb":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    let effect = args.dropFirst().first ?? "help"
    func parseHex(_ s: String) -> RGB? {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGB(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }
    do {
        let report: RazerReport
        switch effect {
        case "static":
            guard let hex = args.dropFirst(2).first, let rgb = parseHex(hex) else {
                print("Usage: rgb static <rrggbb>   e.g. `rgb static ff0000` (red)")
                exit(64)
            }
            print("Setting static \(hex) …")
            report = RazerCommands.setStatic(rgb: rgb)
        case "spectrum":
            print("Setting spectrum cycle …"); report = RazerCommands.setSpectrum()
        case "wave":
            print("Setting wave …"); report = RazerCommands.setWave()
        case "off":
            print("Turning lighting off …"); report = RazerCommands.setNone()
        default:
            print("Usage: rgb <static rrggbb | spectrum | wave | off>")
            exit(64)
        }
        let resp = try dev.sendWithRetry(report)
        let ok = resp.status == RazerStatus.successful.rawValue
        print("  status = 0x\(String(resp.status, radix: 16)) \(ok ? "✓" : "⚠︎")")
    } catch {
        print("RGB command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

default:
    print("Unknown command: \(command)")
    print("Available: info, battery, dpi [x] [y], poll [hz], stages [d1,d2,…] [active], rgb <static rrggbb|spectrum|wave|off>, brightness [pct], login-item [on|off]")
    exit(64)
}
