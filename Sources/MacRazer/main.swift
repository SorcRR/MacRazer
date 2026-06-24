// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

// Milestone 1/2 CLI probe: open the device over the 2.4GHz dongle and attempt a battery
// read. This is the lowest-risk validation that HID communication works from Swift/IOKit
// before any UI is built. Expect the battery read to possibly time out over wireless —
// that's the known issue from openrazer/openrazer#2583.
//
// Usage:
//   swift run MacRazer            # probe + battery read
//   swift run MacRazer battery    # same, explicit
//   (DPI / polling / RGB writes will be added as subcommands as each milestone lands)

import AppKit
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

func openDevice() -> HIDDevice? {
    do {
        let dev = try HIDDevice.open(vendorId: Razer.vendorId)
        print("✓ Opened \(dev.productName) (VID 0x1532, PID 0x\(String(format: "%04x", dev.productID)))")
        return dev
    } catch {
        print("✗ \(error)")
        return nil
    }
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
    print("Found \(devices.count) HID interface(s) for the Cobra HyperSpeed:")
    for (i, dev) in devices.enumerated() {
        print("  [\(i)] \(HIDDevice.describe(dev))")
    }

case "render-ui":
    // Render the popover to a PNG for static visual inspection (no device needed).
    _ = NSApplication.shared
    let path = args.dropFirst().first ?? "ui-preview.png"
    let controller = MouseController()
    controller.loadPreviewState()
    if args.contains("offline") { controller.setPreviewOffline() }
    let rootView: AnyView = args.contains("color")
        ? AnyView(ColorPickerPage(color: .constant(.blue), onBack: {}, onApply: { _ in }))
        : AnyView(PopoverView(controller: controller, remapper: ButtonRemapper()))
    let renderer = ImageRenderer(content: rootView.padding(1).background(Color(white: 0.13)))
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

case "render-remap":
    _ = NSApplication.shared
    let path = args.dropFirst().first ?? "remap-preview.png"
    let r = ButtonRemapper()
    r.loadPreviewState()
    let renderer = ImageRenderer(content: RemapView(remapper: r).padding(1).background(Color(white: 0.13)))
    renderer.scale = 2
    if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path)); print("Wrote \(path)")
    } else { print("Render failed") }

case "icon":
    // Render the menu bar mark to a PNG for visual inspection.
    let path = args.dropFirst().first ?? "icon-preview.png"
    MenuBarIcon.writePreview(to: path, size: 256)
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
        print("(This is the documented wireless-dongle timeout. Try: re-seat the dongle, ")
        print(" move the mouse to wake it, or test over wired USB-C to compare.)")
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
        exit(2)
    }

case "brightness":
    guard let dev = openDevice() else { exit(1) }
    defer { dev.close() }
    func dump(_ r: RazerReport) -> String {
        "status=0x\(String(r.status, radix: 16)) args[0..5]=" + r.arguments[0..<6].map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    do {
        let r = try dev.sendWithRetry(RazerCommands.getBrightness())
        print("GET brightness (led ZERO=0x00): \(dump(r)) → \(RazerCommands.brightnessPercent(fromRaw: r.arguments[2]))%")
        // Also probe BACKLIGHT (0x05) and LOGO (0x04) LEDs in case the lit zone differs.
        for (name, led) in [("BACKLIGHT", UInt8(0x05)), ("LOGO", UInt8(0x04))] {
            let rr = try dev.sendWithRetry(RazerCommands.getBrightness(led: led))
            print("GET brightness (led \(name)=0x\(String(led, radix: 16))): \(dump(rr))")
        }
        if let arg = args.dropFirst().first, let pct = Int(arg) {
            let raw = RazerCommands.brightnessRaw(fromPercent: pct)
            print("SET brightness \(pct)% (raw \(raw)) on ZERO_LED …")
            let sr = try dev.sendWithRetry(RazerCommands.setBrightness(raw))
            print("  set: \(dump(sr))")
            let back = try dev.sendWithRetry(RazerCommands.getBrightness())
            print("  read-back: \(dump(back)) → \(RazerCommands.brightnessPercent(fromRaw: back.arguments[2]))%")
        }
    } catch {
        print("Brightness probe failed: \(error)"); exit(2)
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
        exit(2)
    }

default:
    print("Unknown command: \(command)")
    print("Available: info, battery, dpi [x] [y], poll [hz], rgb <static rrggbb|spectrum|wave|off>")
    exit(64)
}
