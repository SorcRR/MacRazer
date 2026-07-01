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
        .executableTarget(
            name: "MacRazer",
            path: "Sources/MacRazer"
        ),
        // Tests import the executable target directly (@testable) — supported by SwiftPM on
        // macOS, and avoids splitting a library target just to gain testability.
        .testTarget(
            name: "MacRazerTests",
            dependencies: ["MacRazer"],
            path: "Tests/MacRazerTests"
        ),
    ]
)
