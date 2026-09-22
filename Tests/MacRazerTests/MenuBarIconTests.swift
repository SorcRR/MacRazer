// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// `MenuBarIcon.Variant` is what `AppDelegate` compares before setting the status item's
/// image. The comparison is what breaks the redraw loop from issue #25, so these pin down
/// which appearance changes count as a different mark and which do not.
final class MenuBarIconTests: XCTestCase {
    private func appearance(_ name: NSAppearance.Name) -> NSAppearance {
        guard let a = NSAppearance(named: name) else {
            XCTFail("no system appearance named \(name.rawValue)")
            return NSAppearance(named: .aqua)!
        }
        return a
    }

    private let light: [NSAppearance.Name] = [
        .aqua, .vibrantLight, .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight,
    ]
    private let dark: [NSAppearance.Name] = [
        .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
    ]

    func testTheIdleMarkIsTheSameForEveryAppearance() {
        // The loop in #25 ran while the mouse was off the charger too. The idle mark is a
        // template, so no appearance report, real or spurious, may count as a reason to set it
        // again.
        for name in light + dark {
            XCTAssertEqual(MenuBarIcon.Variant(charging: false, appearance: appearance(name)), .idle,
                           name.rawValue)
        }
    }

    func testTheChargingMarkFollowsLightAndDark() {
        // The menu bar hands out the vibrant appearances, and Increase Contrast swaps in the
        // high-contrast ones. Each has to land on the right side, or the bolt is drawn for the
        // wrong background.
        for name in light {
            XCTAssertEqual(MenuBarIcon.Variant(charging: true, appearance: appearance(name)),
                           .charging(dark: false), name.rawValue)
        }
        for name in dark {
            XCTAssertEqual(MenuBarIcon.Variant(charging: true, appearance: appearance(name)),
                           .charging(dark: true), name.rawValue)
        }
    }

    func testOnlyARealChangeIsADifferentMark() {
        // What the guard in `AppDelegate.showMenuBarIcon` relies on: asking again with nothing
        // changed gives an equal variant, so the image is left alone and the loop stops.
        // Plugging in or unplugging, or the menu bar flipping, still gets a new image.
        let dark = appearance(.darkAqua), light = appearance(.aqua)
        XCTAssertEqual(MenuBarIcon.Variant(charging: true, appearance: dark),
                       MenuBarIcon.Variant(charging: true, appearance: dark))
        XCTAssertNotEqual(MenuBarIcon.Variant(charging: true, appearance: dark),
                          MenuBarIcon.Variant(charging: true, appearance: light))
        XCTAssertNotEqual(MenuBarIcon.Variant(charging: true, appearance: dark),
                          MenuBarIcon.Variant(charging: false, appearance: dark))
    }
}
