// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Minimal registry of Razer mice. The connected device reports its own name via the USB
/// product string, so detection works for ANY Razer mouse; this table adds per-model
/// capabilities (verified protocol, battery, lighting, max DPI) so the UI shows only what
/// applies.
///
/// To extend support to more models, port their specifics from OpenRazer
/// (daemon `mouse.py` METHODS/DPI_MAX, driver `razermouse_driver.c`) and add them here.
struct RazerDeviceInfo {
    let pid: Int
    let name: String
    let fullySupported: Bool
    let hasBattery: Bool
    let hasLighting: Bool
    let maxDPI: Int
}

enum RazerDevices {
    static let vendorID = 0x1532

    static let known: [RazerDeviceInfo] = [
        .init(pid: 0x00DB, name: "Razer Cobra HyperSpeed", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 26000),
        .init(pid: 0x00DA, name: "Razer Cobra HyperSpeed (Wired)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 26000),
        .init(pid: 0x00A3, name: "Razer Cobra", fullySupported: true, hasBattery: false, hasLighting: true, maxDPI: 8500),
        .init(pid: 0x00AF, name: "Razer Cobra Pro (Wired)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 30000),
        .init(pid: 0x00B0, name: "Razer Cobra Pro (Wireless)", fullySupported: true, hasBattery: true, hasLighting: true, maxDPI: 30000),
        .init(pid: 0x0062, name: "Razer Atheris", fullySupported: true, hasBattery: true, hasLighting: false, maxDPI: 7200),
    ]

    static func info(pid: Int) -> RazerDeviceInfo? { known.first { $0.pid == pid } }
    static func fullySupported(pid: Int) -> Bool { info(pid: pid)?.fullySupported ?? false }
    /// Defaults assume a full-featured mouse for unknown models (so we still attempt controls).
    static func hasBattery(pid: Int) -> Bool { info(pid: pid)?.hasBattery ?? true }
    static func hasLighting(pid: Int) -> Bool { info(pid: pid)?.hasLighting ?? true }
    static func maxDPI(pid: Int) -> Int { info(pid: pid)?.maxDPI ?? 26000 }
}
