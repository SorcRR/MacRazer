// swift-tools-version:6.1
// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.
import PackageDescription

let package = Package(
    name: "MacRazer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // CLI probe target — milestone 1/2: validate HID + battery read against
        // real hardware before any UI is built. Evolves into the menu bar app later.
        .executableTarget(
            name: "MacRazer",
            path: "Sources/MacRazer"
        )
    ]
)
