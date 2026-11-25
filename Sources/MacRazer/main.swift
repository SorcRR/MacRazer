// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

// Entry point. No arguments launches the menu bar app; subcommands are CLI diagnostics
// against real hardware (battery / dpi / poll / rgb / brightness / buttons / info) plus render-*
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
if command.hasPrefix("render") {
    RenderOptions.isActive = true
    AppInfo.renderVersion = args.first { $0.hasPrefix("version=") }.map { String($0.dropFirst("version=".count)) }
    if let crop = args.first(where: { $0.hasPrefix("crop=") }) {
        // Every part a number: dropping the ones that aren't could still leave four, of the wrong crop.
        let parts = crop.dropFirst("crop=".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0) }
        let n = parts.compactMap { $0 }
        guard parts.count == 4, n.count == 4, n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0 else {
            status("crop= takes four numbers in points, a size above zero: crop=x,y,width,height")
            exit(1)
        }
        RenderOptions.crop = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
}

/// Status and diagnostics: which device opened, why it didn't, how to fix that. They go to
/// stderr so stdout carries only a command's results, and `devicetest > report.json` (or
/// any other redirect) gets the results alone while the person still sees the rest.
func status(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Turn a permission-denied failure into the fix, instead of leaving a bare hex code on
/// screen. The GUI already does this (PopoverView / PermissionsModel); every CLI catch
/// routes through here so it does too. Returns whether the error was a permission problem,
/// so callers can suppress advice that would then be misleading.
@discardableResult
func printPermissionHintIfDenied(_ error: Error) -> Bool {
    guard HIDDevice.errorLooksPermissionDenied(String(describing: error)) else { return false }
    status("  → macOS is refusing HID access (Input Monitoring).")
    status("    Running via `swift run MacRazer …`? The grant belongs to the terminal that")
    status("    launched it, not to the SwiftPM binary — grant Terminal (or iTerm/your IDE) in")
    status("    System Settings › Privacy & Security › Input Monitoring, then start a new")
    status("    terminal session and retry.")
    status("    Running MacRazer.app? Grant MacRazer itself there, then relaunch it — macOS")
    status("    only applies the grant to a freshly-launched app.")
    return true
}

func openDevice() -> HIDDevice? {
    // These commands only speak USB. With the mouse on Bluetooth and the dongle still plugged
    // in, they would open the idle dongle and every read would time out with no hint why.
    if let bt = HIDDevice.bluetoothRazerMouse() {
        status("Note: \(bt.name) is connected over Bluetooth, which these commands can't reach.")
        status("      If that's the mouse to probe, switch it to the dongle or plug in the cable.")
    }
    do {
        let dev = try HIDDevice.open(vendorId: Razer.vendorId)
        status("✓ Opened \(dev.productName) (VID 0x1532, PID 0x\(String(format: "%04x", dev.productID)))")
        return dev
    } catch {
        status("✗ \(error)")
        printPermissionHintIfDenied(error)
        return nil
    }
}

/// The look a `render-*` command draws in: `light` or `green` among its arguments picks the
/// solid Light or Razer Green theme, otherwise solid Dark. Solid rather than glass, because a
/// render has no desktop behind it to show through.
func renderTheme(_ args: [String]) -> PopoverTheme {
    args.contains("light") ? .light : args.contains("green") ? .razerGreen : .dark
}

func renderLook(_ args: [String]) -> PopoverLook {
    PopoverLook.resolve(theme: renderTheme(args), glass: false, systemIsDark: true)
}

/// Shared by the render-* commands: draw a SwiftUI view at 2x on a theme's backdrop and write
/// it to a PNG.
///
/// `ImageRenderer` is quick but draws every native control (menus, text fields, most buttons)
/// as a yellow placeholder, so it only suits views made of shapes and text. Prefer
/// `writeHostedPNG` for anything meant to be seen.
@MainActor func writeViewPNG<V: View>(_ view: V, look: PopoverLook, to path: String) {
    guard RenderOptions.crop == nil else {
        renderFailed("crop= works on hosted renders only. Add `hosted`.")
    }
    // In the look's colour scheme, to match its backdrop. Without it `.secondary` and
    // `.tertiary` resolve for the other scheme and read as a contrast bug that isn't there.
    let renderer = ImageRenderer(
        content: view.environment(\.colorScheme, look.isDark ? .dark : .light).padding(1)
            .background(Color(nsColor: look.backdropColor ?? .windowBackgroundColor)))
    renderer.scale = 2
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        writeRender(png, to: path)
    } else {
        renderFailed()
    }
}

/// A render that didn't happen exits non-zero, so a caller can tell it from one that did.
func renderFailed(_ why: String = "") -> Never {
    status(why.isEmpty ? "Render failed" : "Render failed: \(why)")
    exit(1)
}

/// Writes a render's PNG, or fails the render: a missing folder isn't a success.
func writeRender(_ png: Data, to path: String) {
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { renderFailed("\(error.localizedDescription)") }
    print("Wrote \(path)")
}

/// Runs AppKit's event loop for a while. `RunLoop.run` alone never hands AppKit its events,
/// and activation and becoming key arrive as events. Keys and clicks are dropped: the render
/// window takes focus for a moment, and whatever the person was typing elsewhere mustn't
/// reach the view being captured.
@MainActor func pumpEvents(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    let input: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                        .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                        .scrollWheel]
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true),
           !input.contains(NSEvent.EventTypeMask(type: event.type)) {
            NSApp.sendEvent(event)
        }
    }
}

/// The window a hosted render is drawn in. A borderless window can't become key on its own,
/// and the popover is key while someone uses it, so this one can too.
final class RenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Renders through a real `NSHostingView` in a real window instead of `ImageRenderer`.
///
/// `ImageRenderer` draws a `ScrollView` as an empty box, since its content is laid out lazily
/// and never makes it into the snapshot, and it draws native controls as placeholders. A view
/// hosted in a window draws both as the app does.
///
/// `size` is optional: a view that sizes itself, like a window's content, is measured with
/// `fittingSize`. Only a scroll view has to be told how much room it has, because it will
/// take whatever it is given.
@MainActor func writeHostedPNG<V: View>(_ view: V, size: CGSize? = nil, look: PopoverLook,
                                        to path: String) {
    // The backdrop the popover or window paints behind its content. `cacheDisplay` captures
    // no window background, so without this the text would sit on nothing.
    let hosted = view.environment(\.colorScheme, look.isDark ? .dark : .light)
        .background(Color(nsColor: look.backdropColor ?? .windowBackgroundColor))
    let host = NSHostingView(rootView: AnyView(hosted))
    host.appearance = NSAppearance(named: look.appearanceName)
    let frameSize = size ?? host.fittingSize
    // A view with no intrinsic size measures as zero, and the capture below then fails with
    // nothing to say about why. Name the cause instead.
    guard frameSize.width > 0, frameSize.height > 0 else {
        renderFailed("the view has no size of its own. Pass an explicit size.")
    }
    host.frame = CGRect(origin: .zero, size: frameSize)
    // Inside a window, ordered in far off screen. Outside one, a view resolves colours
    // without the window's colour space (the swatches came out oversaturated) and
    // `onAppear` never runs, so a preview state set there wouldn't show.
    let window = RenderWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: frameSize),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: look.appearanceName)
    // sRGB whatever display the window lands on, so a render's colours don't depend on the
    // Mac that made it (a P3 laptop panel and an sRGB monitor gave different swatches).
    window.colorSpace = .sRGB
    window.contentView = host
    // Active and key, as the app is while its popover is open: only then do switches that are
    // on draw green. macOS lets only a launched app activate itself, so this works when the
    // render runs from an app bundle opened with `open` (Scripts/render-screenshots.sh). Run
    // from a terminal, it's ignored and switches draw grey.
    NSApp.finishLaunching()
    // The deprecated call on purpose: `activate()` is cooperative, and a launched render that
    // nobody handed focus to stays inactive with it, so the switches came out grey.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    // Long enough for `onAppear` and the layout pass it causes.
    pumpEvents(for: 0.5)
    host.layoutSubtreeIfNeeded()
    host.display()
    guard var image = windowServerImage(window) ?? cachedDisplayImage(host) else { renderFailed() }
    if let crop = RenderOptions.crop {
        // Points to pixels; the window server's image is at the display's scale.
        let scale = CGFloat(image.width) / host.bounds.width
        // Whole pixels, as `cropping(to:)` would round it anyway; a crop that comes back
        // smaller ran off the edge of the render.
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                            width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = image.cropping(to: pixels),
              cropped.width == Int(pixels.width), cropped.height == Int(pixels.height) else {
            renderFailed("crop \(crop) doesn't fit in the \(host.bounds.size) render.")
        }
        image = cropped
    }
    // The window server hands back the main display's colour space (Display P3 on a MacBook,
    // a monitor's own profile on another). Convert to sRGB so the same render comes out the
    // same whichever display it ran on, and reads right where the profile is ignored.
    if let srgb = CGColorSpace(name: CGColorSpace.sRGB), image.colorSpace?.name != srgb.name,
       let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                           bytesPerRow: 0, space: srgb,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let converted = ctx.makeImage() { image = converted }
    }
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        renderFailed()
    }
    writeRender(png, to: path)
}

/// The window as the window server composited it: exactly what the app shows on screen. A
/// process may capture its own windows without the Screen Recording permission.
///
/// Preferred over `cacheDisplay`, which redraws the views itself and gets some AppKit controls
/// wrong: sliders with a step came out as solid white bars.
///
/// The capture is checked against the window's size: the hosting view resizes its window to
/// fit the content after the first layout, and a capture taken mid-resize came out scaled and
/// cropped. One that doesn't match is taken again.
@MainActor private func windowServerImage(_ window: NSWindow) -> CGImage? {
    if window.backingScaleFactor != 2 {
        status("Note: the display is at \(window.backingScaleFactor)x, so this render is too, not 2x.")
    }
    for _ in 0..<10 {
        let scale = window.backingScaleFactor
        let expected = (Int((window.frame.width * scale).rounded()), Int((window.frame.height * scale).rounded()))
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                               [.boundsIgnoreFraming, .bestResolution]),
           (image.width, image.height) == expected {
            return image
        }
        pumpEvents(for: 0.2)
    }
    status("The window server's capture never matched the window's size; drawing it directly instead.")
    return nil
}

/// The fallback when the window server gives nothing back.
@MainActor private func cachedDisplayImage(_ view: NSView) -> CGImage? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
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
    if args.contains("held") { controller.setPreviewHeldByAnotherApp() }
    if args.contains("held-at-launch") { controller.setPreviewHeldAtLaunch() }
    if args.contains("bluetooth") { controller.setPreviewBluetooth() }
    if args.contains("bluetooth-connected") { controller.setPreviewBluetoothConnected() }
    let updateChecker = UpdateChecker()
    if args.contains("update") { updateChecker.loadPreviewState(notes: PreviewNotes.releaseBody) }
    if args.contains("updated") { updateChecker.loadPreviewUpdated(notes: PreviewNotes.releaseBody) }
    if args.contains("downloading") { updateChecker.loadPreviewState(phase: .downloading(0.42)) }
    let launchAtLogin = LaunchAtLogin()
    launchAtLogin.loadPreviewState()
    // Accessories under "Other Razer devices": `keyboard` (Cynosa Chroma), `pad` (Firefly V2),
    // `three` (both plus an untested Ornata V3), `untested` (the Ornata V3 alone, open). Then `follow` (the keyboard follows the
    // mouse), `wave`, `synapse` (Synapse running; `macrazer` gives the pad back to MacRazer).
    var accessoryPIDs: [Int] = []
    if args.contains("keyboard") || args.contains("three") { accessoryPIDs.append(0x022A) }
    if args.contains("pad") || args.contains("three") { accessoryPIDs.append(0x0C04) }
    if args.contains("three") { accessoryPIDs.append(0x02A1) }
    if args.contains("untested") { accessoryPIDs.append(0x028F) }
    if !accessoryPIDs.isEmpty {
        Accessories.shared.loadPreviewState(pids: accessoryPIDs,
                                            followsMouse: args.contains("follow") ? [0x022A] : [],
                                            synapse: args.contains("synapse"), wave: args.contains("wave"),
                                            useMacRazer: args.contains("macrazer") ? [0x0C04] : [])
    }
    // The notes page is its own render: it is a scroll view, so it needs the hosted path,
    // and it is sized to the height the main page renders at — the whole point of checking
    // it is whether the notes fit there.
    if args.contains("whatsnew") {
        // `installed` is the same page reached from the "Updated to …" card: same notes, no
        // button, because there is nothing left to install.
        let installed = args.contains("installed")
        if installed {
            updateChecker.loadPreviewSpan([
                RemoteRelease(version: "0.4.1", body: PreviewNotes.previousReleaseBody),
                RemoteRelease(version: "0.4.0", body: PreviewNotes.releaseBody),
            ])
        } else {
            updateChecker.loadPreviewState(notes: PreviewNotes.releaseBody)
        }
        writeHostedPNG(WhatsNewPage(version: updateChecker.latestVersion ?? AppInfo.displayVersion,
                                    releases: installed ? updateChecker.installedNotes
                                                        : updateChecker.latestNotes,
                                    canInstallInPlace: updateChecker.canInstallInPlace,
                                    onBack: {}, onUpdate: installed ? nil : {}),
                       size: CGSize(width: PopoverLayout.oneColumnWidth, height: 748), look: renderLook(args), to: path)
        break
    }
    // `twocolumns`: the two-column layout with only the mouse. Scratch defaults, so a render
    // never changes the setting.
    let renderAppearance = AppearanceSettings(defaults: UserDefaults(suiteName: "MacRazer.render-ui") ?? .standard)
    renderAppearance.twoColumns = args.contains("twocolumns")
    renderAppearance.glass = false
    renderAppearance.theme = renderTheme(args)
    // The same two remaps as `render-remap`, so the Buttons row reads "2 remapped" as it does in use.
    let renderRemapper = ButtonRemapper()
    renderRemapper.loadPreviewState()
    let rootView: AnyView = args.contains("color")
        ? AnyView(ColorPickerPage(color: .constant(.blue),
                                  device: accessoryPIDs.isEmpty ? nil
                                      : .init(symbol: AccessoryKind.mousepad.symbol, name: "Razer Firefly V2", kind: "Mousepad"),
                                  onBack: {}, wide: args.contains("twocolumns"), onApply: { _ in })
                    .frame(width: args.contains("twocolumns") ? PopoverLayout.twoColumnWidth : PopoverLayout.oneColumnWidth))
        : args.contains("usage")
        ? AnyView(UsageGraphView(controller: controller, onBack: {}))
        : args.contains("profiles")
        ? AnyView(ProfilesView(controller: controller, remapper: ButtonRemapper(), onBack: {},
                                width: PopoverLayout.oneColumnWidth))
        : AnyView(PopoverView(controller: controller, remapper: renderRemapper, updateChecker: updateChecker,
                              launchAtLogin: launchAtLogin, appearance: renderAppearance,
                              onOpenSettings: {},
                              onOpenDeviceTest: {}, onTestAccessory: { _ in }, // no windows in a render
                              previewEditingStages: args.contains("stages")))
    // `hosted` draws native controls (segmented pickers, switches) instead of placeholders.
    if args.contains("hosted") { writeHostedPNG(rootView, look: renderLook(args), to: path) } else { writeViewPNG(rootView, look: renderLook(args), to: path) }

case "render-settings":
    _ = NSApplication.shared
    let renderSuite = "MacRazer.render-settings"
    let renderDefaults = UserDefaults(suiteName: renderSuite)!
    renderDefaults.removePersistentDomain(forName: renderSuite)
    defer { renderDefaults.removePersistentDomain(forName: renderSuite) }
    let renderScrolling = ScrollSettings(defaults: renderDefaults, sourceIdentificationAvailable: true)
    renderScrolling.setEnabled(args.contains("reversed"))
    renderScrolling.loadPreviewState()
    let settingsPath = outputPath(args.dropFirst(), default: "settings-preview.png")
    let sc = MouseController()
    sc.loadPreviewState()
    let sl = LaunchAtLogin()
    sl.loadPreviewState()
    let su = UpdateChecker()
    // `update` shows the Updates section in its available state, which is the only way to see
    // the Install Now button without waiting for a real release.
    if args.contains("update") { su.loadPreviewState() }
    // A page name (`privacy`, `appearance`, `updates`) opens that page instead of General.
    let settingsPane = SettingsPane.allCases.first { args.contains($0.rawValue) } ?? .general
    // Hosted rather than `ImageRenderer`: each page is a scroll view.
    writeHostedPNG(SettingsView(controller: sc, launchAtLogin: sl, updateChecker: su, onDone: {},
                                scrolling: renderScrolling,
                                usageStats: .preview(consent: args.contains("notsharing") ? .declined : .granted),
                                pane: settingsPane),
                   size: SettingsView.size, look: renderLook(args), to: settingsPath)

case "render-updated":
    // The window shown on the first launch after an update. `nonotes` shows the fallback
    // link a release with no cached body gets.
    _ = NSApplication.shared
    let updatedPath = outputPath(args.dropFirst(), default: "updated-preview.png")
    let uc = UpdateChecker()
    if args.contains("nonotes") {
        uc.loadPreviewUpdated()
    } else {
        uc.loadPreviewSpan([
            RemoteRelease(version: "0.4.1", body: PreviewNotes.previousReleaseBody),
            RemoteRelease(version: "0.4.0", body: PreviewNotes.releaseBody),
        ])
    }
    // `asked` leaves out the usage stats card, as for someone who already answered.
    writeHostedPNG(UpdatedView(updateChecker: uc, onDone: {},
                               usageStats: .preview(consent: args.contains("asked") ? .granted : .undecided)),
                   look: renderLook(args), to: updatedPath)

case "render-usage-consent":
    // The one-time usage stats question a new install gets.
    _ = NSApplication.shared
    writeHostedPNG(UsageStatsConsentView(stats: .preview(consent: .undecided), onDone: {}),
                   look: renderLook(args), to: outputPath(args.dropFirst(), default: "usage-consent-preview.png"))

case "render-support-prompt":
    // The window asking to test a mouse. `noaccess` shows the Input Monitoring version, with a
    // made-up mouse. `partly` shows a partly verified one (the Basilisk V4 Pro), and `links` one
    // verified on its dongle whose cable still needs a test (the Naga Pro).
    _ = NSApplication.shared
    let mouse = args.contains("partly")
        ? UnsupportedMouse(pid: 0x00E3, name: "Razer Basilisk V4 Pro", canControl: true)
        : args.contains("links")
        ? UnsupportedMouse(pid: 0x0090, name: "Razer Naga Pro", canControl: true)
        : UnsupportedMouse(pid: 0xFFFE, name: "Razer DeathAdder V3 Pro", canControl: !args.contains("noaccess"))
    writeHostedPNG(SupportPromptView(mouse: mouse, onRunTest: {}, onNotNow: {}, onDontAsk: {}),
                   look: renderLook(args), to: outputPath(args.dropFirst(), default: "support-prompt-preview.png"))

case "render-about":
    _ = NSApplication.shared
    let aboutPath = outputPath(args.dropFirst(), default: "about-preview.png")
    // `notes` shows the "What's new in …" row, which is otherwise only there once the app has
    // cached a release body.
    //
    // Hosted rather than `ImageRenderer`: this window is mostly buttons and links, and
    // `ImageRenderer` draws every native control as a yellow placeholder — which is to say it
    // could not show the one thing an About preview is for.
    writeHostedPNG(AboutView(onDone: {}, // no window to close in a render
                               notes: args.contains("notes")
                                 ? [VersionedNotes(version: AppInfo.displayVersion,
                                                   notes: ReleaseNotes.parse(PreviewNotes.releaseBody))]
                                 : []),
                   look: renderLook(args), to: aboutPath)

case "render-device-test":
    // One screen of the device test, for checking layout and wording without a mouse:
    // `render-device-test <stage> [unknown|partly|unlit|wiredonly|dock] [several] [ran] [sent|failed] [path.png]`, stage one of
    // intro, permission, identify, battery, dpi, polling, lighting, buttons, review.
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "device-test-preview.png")
    let stages: [String: DeviceTestModel.Stage] = [
        "intro": .intro, "permission": .permission, "identify": .identify, "battery": .battery,
        "dpi": .dpi, "polling": .polling, "lighting": .lighting, "buttons": .buttons, "review": .review,
    ]
    let stage = args.dropFirst().compactMap { stages[$0] }.first ?? .intro
    let controller = MouseController()
    controller.loadPreviewState()
    // `noworker` shows the review as a build without the Worker has it: no Send, no reply email.
    let model = DeviceTestModel(controller: controller, permissions: PermissionsModel(),
                                reportEndpoint: args.contains("noworker") ? nil : URL(string: "https://reports.example/"))
    // `unknown` and `partly` pick the intro: a model off the registry, and the Basilisk V4 Pro,
    // whose polling rate is still unverified. `unlit` and `wiredonly` show the steps for what a
    // mouse doesn't have: the Viper V3 HyperSpeed's lights and the Naga Trinity's battery.
    let pid = args.contains("dock") ? 0x00A4 : args.contains("unknown") ? 0x9999 : args.contains("partly") ? 0x00E3
        : args.contains("unlit") ? 0x00B8 : args.contains("wiredonly") ? 0x0067 : 0x00DB
    model.loadPreview(stage, pid: pid, ranSteps: args.contains("ran"))
    // `several` shows the intro's hint with two devices plugged in: a Mouse Dock and its dongle.
    if args.contains("several") {
        model.loadPreviewDevices([
            .init(key: .init(pid: 0x007E, locationID: 0x1100000), name: "Razer Mouse Dock", index: 0),
            .init(key: .init(pid: 0x0088, locationID: 0x1200000), name: "Razer Basilisk Ultimate Dongle", index: 1),
        ])
    }
    if args.contains("sent") { model.previewSendState(.sent) }
    if args.contains("failed") { model.previewSendState(.failed(.tooMany)) }
    writeHostedPNG(DeviceTestView(model: model, onClose: {}), look: renderLook(args), to: path)

case "render-accessory-test":
    // The lighting test for a keyboard or mousepad, without one plugged in:
    // `render-accessory-test [intro|lighting|review] [pad] [sent] [path.png]`.
    _ = NSApplication.shared
    let accessoryPath = outputPath(args.dropFirst(), default: "accessory-test-preview.png")
    let accessoryStage: AccessoryTestModel.Stage = args.contains("review") ? .review
        : args.contains("lighting") ? .lighting : .intro
    let accessoryInfo = RazerAccessories.info(pid: args.contains("pad") ? 0x0C08 : 0x028F)!
    let previewAccessory = AccessoryController(id: .init(pid: accessoryInfo.pid, locationID: 0), info: accessoryInfo)
    previewAccessory.loadPreviewState()
    let accessoryModel = AccessoryTestModel(reportEndpoint: URL(string: "https://reports.example/"))
    accessoryModel.loadPreview(accessoryStage, accessory: previewAccessory, sent: args.contains("sent"))
    writeHostedPNG(AccessoryTestView(model: accessoryModel, onClose: {}), look: renderLook(args), to: accessoryPath)

case "render-crash-report":
    // The window shown on the launch after a crash. `sent` shows the thank-you, `failed` a
    // send that didn't go.
    _ = NSApplication.shared
    let crashPath = outputPath(args.dropFirst(), default: "crash-report-preview.png")
    let crashModel = CrashReportModel.preview()
    if args.contains("sent") { crashModel.loadPreviewSent() }
    if args.contains("failed") {
        crashModel.loadPreviewFailed(args.contains("cap") ? .tooMany : args.contains("refused") ? .refused : .unavailable)
    }
    writeHostedPNG(CrashReportView(model: crashModel, onDone: {}, onDontAskAgain: {}), look: renderLook(args), to: crashPath)

case "render-issue-report":
    // "Report an Issue…". `sent` shows the thank-you, `failed` a send that didn't go.
    _ = NSApplication.shared
    let issuePath = outputPath(args.dropFirst(), default: "issue-report-preview.png")
    let issueModel = IssueReportModel.preview()
    if args.contains("sent") { issueModel.loadPreviewSent(replyEmail: "sam@example.com") }
    if args.contains("failed") {
        issueModel.description = "The battery reads 0% after waking from sleep, until I unplug the dongle."
        issueModel.loadPreviewFailed(args.contains("cap") ? .tooMany : .unavailable)
    }
    writeHostedPNG(IssueReportView(model: issueModel, onClose: {}), look: renderLook(args), to: issuePath)

case "render-remap":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "remap-preview.png")
    let r = ButtonRemapper()
    r.loadPreviewState()
    // `wide`: the popover's two-column Buttons page, with the DPI button section.
    // `side-buttons`: the window with the notice for side buttons saved to other functions.
    if args.contains("side-buttons") {
        let mouse = MouseController()
        mouse.loadPreviewState()
        mouse.setPreviewSideButtonsRemapped()
        writeHostedPNG(RemapView(remapper: r, controller: mouse), look: renderLook(args), to: path)
    } else if args.contains("wide") {
        let mouse = MouseController()
        mouse.loadPreviewState()
        writeHostedPNG(RemapView(remapper: r, controller: mouse, onBack: {}, width: PopoverLayout.twoColumnWidth, twoColumns: true),
                       look: renderLook(args), to: path)
    } else {
        writeHostedPNG(RemapView(remapper: r), look: renderLook(args), to: path)
    }

case "render-permissions":
    _ = NSApplication.shared
    let path = outputPath(args.dropFirst(), default: "permissions-preview.png")
    let controller = MouseController()
    controller.loadPreviewState()
    let model = PermissionsModel()
    model.loadPreviewState()
    writeHostedPNG(PermissionsView(model: model, controller: controller), look: renderLook(args), to: path)

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
        status("Render failed")
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

case "buttons":
    // Read the side buttons' entries in the mouse's own table, and optionally put back the
    // factory blocks. The same read the Configure Buttons notice uses over USB
    // (`SideButtonReset`), exposed so a contributor can check a model without the GUI.
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    let canResetOverUSB = RazerDevices.resetsOnboardSideButtonsOverUSB(pid: dev.productID)
    do {
        var remaps: [SideButtonReset.Remap] = []
        for id in SideButtonReset.ids {
            let reply = try dev.sendWithRetry(RazerCommands.getButtonFunction(id: id))
            guard let block = SideButtonReset.usbBlock(id: id, reply: reply) else {
                print("\(SideButtonReset.name(id)): the reply named entry \(String(format: "0x%02x", reply.arguments[1])), not this one.")
                exit(2)
            }
            let text = SideButtonReset.describe(block) ?? "a function MacRazer can't name"
            print("\(SideButtonReset.name(id)): \(text)  [\(block.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            if let remap = SideButtonReset.remap(id: id, block: block) { remaps.append(remap) }
        }
        guard args.contains("reset") else {
            if !remaps.isEmpty {
                print("\(remaps.count) side button(s) hold another function. `buttons reset` puts them back.")
            }
            exit(0)
        }
        guard canResetOverUSB else {
            print("This model has no confirmed USB reset; nothing written.")
            exit(2)
        }
        guard !remaps.isEmpty else {
            print("Nothing to reset.")
            exit(0)
        }
        for remap in remaps {
            try SideButtonReset.reset(remap: remap, on: dev)
            print("\(SideButtonReset.name(remap.id)): reset.")
        }
    } catch {
        print("Button table failed: \(error)")
        exit(2)
    }

case "battery":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    do {
        let battery = try DeviceProbe.battery(dev)
        let resp = battery.response
        let raw = battery.value
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
        let before = try DeviceProbe.readDPI(dev).value
        print("Current DPI: x=\(before.x) y=\(before.y)")

        // If a value was given, set it and read back to confirm it persisted.
        if let arg = args.dropFirst().first, let x = UInt16(arg) {
            let y = args.dropFirst(2).first.flatMap { UInt16($0) } ?? x
            print("Setting DPI to x=\(x) y=\(y) …")
            let check = try DeviceProbe.writeDPI(dev, DeviceProbe.DPI(x: x, y: y))
            print("  set status = 0x\(String(check.setResponse.status, radix: 16))")
            let after = check.readBack.value
            print("Read-back DPI: x=\(after.x) y=\(after.y)")
            if check.confirmed {
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
        let before = try DeviceProbe.readStages(dev).value
        print("Current stages: \(before.stages) (active byte = \(before.activeByte))")
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
            let write = try DeviceProbe.writeStages(dev, stages: stages, activeStage: active)
            print("  set status = 0x\(String(write.setResponse.status, radix: 16))")
            let after = write.readBack.value
            print("Read-back: \(after.stages) (active byte = \(after.activeByte))")
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
        let rate2 = RazerDevices.usesPollingRate2(pid: dev.productID)
        // 250 Hz too on the classic command: not in OpenRazer's table, but the byte is 1000
        // over the rate.
        let rates = rate2 ? RazerDevices.pollingRates(pid: dev.productID)
                          : (RazerCommands.supportedPollingRates + [250]).sorted()
        let before = try DeviceProbe.readPollingRate(dev, usesPollingRate2: rate2).value
        print("Current polling rate: \(before)Hz")
        if let arg = args.dropFirst().first, let hz = Int(arg) {
            guard rates.contains(hz) else {
                print("Unsupported rate. Choose one of: \(rates.map { "\($0)" }.joined(separator: ", "))Hz")
                exit(64)
            }
            print("Setting polling rate to \(hz)Hz …")
            let check = try DeviceProbe.writePollingRate(dev, hz: hz, usesPollingRate2: rate2)
            print("  set status = 0x\(String(check.setResponse.status, radix: 16))")
            print("Read-back: \(check.readBack.value)Hz")
            print(check.confirmed ? "✓ Polling rate write confirmed" : "⚠︎ Read-back doesn't match.")
        } else {
            print("(pass a value to set: \(rates.map { "\($0)" }.joined(separator: "/"))Hz, e.g. `poll 1000`)")
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
        // Every LED group, LOGO first. A refusal on any one of them, LOGO included, is
        // expected on some models (the Basilisk V3 X HyperSpeed lights only its scroll wheel
        // and answers 0x03 for LOGO), so the sweep reports it and carries on: the whole point
        // is to discover which LEDs answer on a model we don't know yet.
        for answer in DeviceProbe.brightnessSweep(dev) {
            let label = "GET brightness (led \(answer.name)=0x\(String(format: "%02x", answer.led)))"
            switch answer.result {
            case .success(let reading):
                print("\(label): \(dump(reading.response))"
                      + " → \(RazerCommands.brightnessPercent(fromRaw: reading.value))%")
            case .failure(let error):
                print("\(label): refused — \(error)")
            }
        }
        if let arg = args.dropFirst().first, let pct = Int(arg) {
            let led = RazerDevices.brightnessLed(pid: dev.productID)
            // The sweep records a refusal per group and carries on; this write throws on one
            // instead, because here it is a real failure to report, not a group that simply
            // doesn't answer.
            let raw = RazerCommands.brightnessRaw(fromPercent: pct)
            print("SET brightness \(pct)% (raw \(raw)) on led 0x\(String(format: "%02x", led)) …")
            let check = try DeviceProbe.writeBrightness(dev, raw: raw, led: led)
            print("  set: \(dump(check.setResponse))")
            print("  read-back: \(dump(check.readBack.response)) → \(RazerCommands.brightnessPercent(fromRaw: check.readBack.value))%")
        }
    } catch {
        // The sweep above handles its own refusals per LED, so only the optional write can
        // reach this — saying "probe failed" would point at the part that just succeeded.
        print("Brightness write failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

case "discover":
    // Which transaction ids the mouse answers to: the first thing to find out about a model
    // the registry doesn't know, since a wrong id makes every other probe fail.
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    // The device test's own Identify step, so this can't choose differently from it.
    let registry = RazerDevices.info(pid: dev.productID)
    let (identify, _) = DeviceTestSteps.identifyMouse(dev, registry: registry)
    guard let found = identify.data else { exit(2) }
    func hex(_ id: UInt8?) -> String { id.map { String(format: "0x%02x", $0) } ?? "none" }
    func show(_ results: [DeviceReport.TransactionResult]) {
        for r in results {
            let groups = r.groups.map { $0.isEmpty ? "" : " on " + $0.joined(separator: ", ") } ?? ""
            print("  \(hex(r.id)): " + (r.answered ? "answered" + groups
                                        : r.refused ? "heard, but refused" : r.error ?? "no group answered"))
        }
    }
    print("Standard commands (firmware read). Registry says \(registry.map { hex($0.transactionId) } ?? "nothing"):")
    show(found.standardAttempts)
    if let dpi = found.dpiAttempts {
        print("No id answered the firmware read, so again with a DPI read:")
        show(dpi)
    }
    for other in found.otherInterfaces ?? [] {
        print(String(format: "Nothing answered, so again on interface usagePage=0x%02x usage=0x%02x:", other.usagePage, other.usage))
        show(other.attempts)
    }
    print("Lighting (brightness sweep). Registry says \(registry.map { hex($0.matrixTransactionId) } ?? "nothing"):")
    show(found.lightingAttempts)
    print("Firmware: \(found.firmware ?? "unknown")")
    print("Would use: \(hex(found.standardId)) for standard commands, \(hex(found.lightingId)) for lighting")

case "devicetest":
    // The in-app device test without its window, for contributors running from source. Every
    // step puts back what it changes. Lighting only dims for a moment: the colour check needs
    // the app's own lighting setting to return to, which only the app knows.
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    let info = RazerDevices.info(pid: dev.productID)
    let (identify, lightSweep) = DeviceTestSteps.identifyMouse(dev, registry: info)
    let (standardId, matrixId) = DeviceTestSteps.chosenIds(identify, registry: info)
    func step<T>(_ body: (DeviceProbeChannel) -> DeviceReport.StepRecord<T>) -> DeviceReport.StepRecord<T> {
        DeviceTestSteps.recorded(dev, standard: standardId, matrix: matrixId,
                                 overrides: info?.transactionOverrides ?? [:], body)
    }
    status("Running. The mouse's lights will go dark for two seconds.")
    let (interfaces, control) = HIDDevice.interfaceSummaries(vendorId: Razer.vendorId)
    var report = DeviceReport(
        appVersion: AppInfo.displayVersion,
        macOSVersion: DeviceReport.currentMacOSVersion,
        device: .init(vendorID: Razer.vendorId, productID: dev.productID, name: dev.productName,
                      connection: nil, interfaces: interfaces, controlInterface: control),
        registry: info.map(DeviceReport.Registry.init),
        identify: identify,
        battery: step { DeviceTestSteps.battery($0, expectsBattery: info?.hasBattery) },
        dpi: step { DeviceTestSteps.dpi($0, maxProbe: false, singleAxis: RazerDevices.singleAxisDPI(pid: dev.productID)) },
        polling: step { DeviceTestSteps.polling($0, usesPollingRate2: RazerDevices.usesPollingRate2(pid: dev.productID)) },
        lighting: step {
            DeviceTestSteps.lighting($0, sweep: lightSweep, restoreEffect: nil,
                                     zoneGroups: DeviceProbe.effectZoneGroups(effectLeds: RazerDevices.effectLeds(pid: dev.productID)),
                                     seconds: 2)
        },
        buttons: .init(),
        capabilities: DeviceTestSteps.capabilities(dev, identify: identify, registry: info))
    report.verdict = report.currentVerdict()
    // Encoded as the app encodes it, so a pasted CLI report reads like an in-app one.
    let json = DeviceReportOutput.json(report, forPublic: true)
    guard !json.isEmpty else {
        status("✗ The report couldn't be encoded.")
        exit(2)
    }
    print(json)

case "bluetoothtest":
    // The in-app Bluetooth test: read-only, for a mouse macOS has connected over Bluetooth.
    guard let mouse = HIDDevice.bluetoothRazerMouse() else {
        status("✗ No Razer mouse is connected over Bluetooth.")
        exit(1)
    }
    // macOS ends a process that touches Bluetooth without saying why in its Info.plist, which
    // only the app bundle has. Built with `swift build`, the binary has none.
    guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
        status("✗ Bluetooth needs the app's Info.plist. Run it from the app: MacRazer.app/Contents/MacOS/MacRazer bluetoothtest")
        exit(1)
    }
    // The running app's own connection to the mouse leaves every read here unanswered, and
    // only the app can let go of it (the in-app test does).
    let me = ProcessInfo.processInfo.processIdentifier
    guard let bundleID = Bundle.main.bundleIdentifier,
          !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != me }) else {
        status("✗ Quit MacRazer first: its own Bluetooth connection keeps the mouse from answering. Or run the test from its menu.")
        exit(1)
    }
    status("Reading \(mouse.name) over Bluetooth. macOS may ask to allow Bluetooth first.")
    let report = DeviceTestSteps.bluetoothTest(name: mouse.name)
    let json = DeviceReportOutput.json(report, forPublic: true)
    guard !json.isEmpty else {
        status("✗ The report couldn't be encoded.")
        exit(2)
    }
    print(json)

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
        case "breathing":
            // No colour: random. One: single. Two: dual.
            let hexes = Array(args.dropFirst(2).prefix(2))
            let colors = hexes.compactMap(parseHex)
            guard colors.count == hexes.count else {
                print("Usage: rgb breathing [rrggbb [rrggbb]]   e.g. `rgb breathing ff0000`")
                exit(64)
            }
            switch colors.count {
            case 0: print("Setting breathing, random colours …"); report = RazerCommands.setBreathingRandom()
            case 1: print("Setting breathing \(hexes[0]) …"); report = RazerCommands.setBreathingSingle(rgb: colors[0])
            default:
                print("Setting breathing \(hexes[0]) / \(hexes[1]) …")
                report = RazerCommands.setBreathingDual(rgb1: colors[0], rgb2: colors[1])
            }
        case "spectrum":
            print("Setting spectrum cycle …"); report = RazerCommands.setSpectrum()
        case "wave":
            // Optional speed byte in hex, lower is faster (`WaveSpeed`): `rgb wave c8` is the
            // slider's slowest, `rgb wave 08` its fastest.
            let speedArg = args.dropFirst(2).first
            guard let speed = speedArg.map({ UInt8($0, radix: 16) }) ?? WaveSpeed.standard else {
                print("Usage: rgb wave [speed]   speed is a hex byte, lower is faster, e.g. `rgb wave c8` (slow)")
                exit(64)
            }
            print(String(format: "Setting wave at speed 0x%02x …", speed)); report = RazerCommands.setWave(speed: speed)
        case "off":
            print("Turning lighting off …"); report = RazerCommands.setNone()
        default:
            print("Usage: rgb <static rrggbb | breathing [rrggbb [rrggbb]] | spectrum | wave [speed] | off>")
            exit(64)
        }
        let resp = try DeviceProbe.applyLighting(dev, report)
        let ok = resp.status == RazerStatus.successful.rawValue
        print("  status = 0x\(String(resp.status, radix: 16)) \(ok ? "✓" : "⚠︎")")
    } catch {
        print("RGB command failed: \(error)")
        printPermissionHintIfDenied(error)
        exit(2)
    }

default:
    print("Unknown command: \(command)")
    print("Available: info, discover, devicetest, bluetoothtest, battery, dpi [x] [y], poll [hz], stages [d1,d2,…] [active], rgb <static rrggbb|breathing [rrggbb [rrggbb]]|spectrum|wave [speed]|off>, brightness [pct], login-item [on|off]")
    exit(64)
}
