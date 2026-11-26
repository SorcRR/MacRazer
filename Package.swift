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
            dependencies: ["MacRazerHoliday"],
            path: "Sources/MacRazer"
        ),
        // The December decorations and the catch game. Its own module so it can't reach the
        // mouse, the remapper or the app's settings: the app hands it what it needs and
        // shows its views at a few marked places, each of which is the plain view off season.
        .target(
            name: "MacRazerHoliday",
            path: "Sources/MacRazerHoliday"
        ),
        .testTarget(
            name: "MacRazerHolidayTests",
            dependencies: ["MacRazerHoliday"],
            path: "Tests/MacRazerHolidayTests"
        ),
        // Tests import the executable target directly (@testable) — supported by SwiftPM on
        // macOS, and avoids splitting a library target just to gain testability.
        .testTarget(
            name: "MacRazerTests",
            dependencies: ["MacRazer"],
            path: "Tests/MacRazerTests",
            // Read from disk by path, not bundled: they're the contract with the Worker, whose
            // CI fetches them from this repository.
            exclude: ["Fixtures"]
        ),
    ]
)
