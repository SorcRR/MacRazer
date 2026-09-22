// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

/// The charging mark picks its colours when it is drawn, not when it is made. That is what
/// lets `AppDelegate` build it once and never watch the menu bar's appearance, and watching
/// the appearance is what caused issue #25. These render the real image and read its pixels.
final class MenuBarIconTests: XCTestCase {
    private let light: [NSAppearance.Name] = [
        .aqua, .vibrantLight, .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight,
    ]
    private let dark: [NSAppearance.Name] = [
        .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark,
    ]

    private enum Ink: Hashable { case white, black, yellowOnDark, yellowOnLight }

    /// Which of the four charging colours appear, fully opaque, when `image` is drawn under
    /// `name`. Drawn at 4x so the 1pt strokes have solid pixels rather than only antialiasing.
    private func inks(_ image: NSImage, drawnAs name: NSAppearance.Name) throws -> Set<Ink> {
        let appearance = try XCTUnwrap(NSAppearance(named: name), name.rawValue)
        let px = Int(image.size.width * 4)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
        }
        let targets: [(Ink, NSColor)] = [
            (.white, .white), (.black, .black),
            (.yellowOnDark, MenuBarIcon.chargingYellowOnDark),
            (.yellowOnLight, MenuBarIcon.chargingYellowOnLight),
        ]
        var found = Set<Ink>()
        for x in 0..<px {
            for y in 0..<px {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95
                else { continue }
                for (ink, t) in targets {
                    guard let t = t.usingColorSpace(.sRGB) else { continue }
                    if abs(c.redComponent - t.redComponent) < 0.06,
                       abs(c.greenComponent - t.greenComponent) < 0.06,
                       abs(c.blueComponent - t.blueComponent) < 0.06 {
                        found.insert(ink)
                    }
                }
            }
        }
        return found
    }

    func testTheChargingMarkIsDrawnForTheMenuBarItLandsOn() throws {
        // The menu bar hands out the vibrant appearances, and Increase Contrast swaps in the
        // high-contrast ones. Each has to land on the right side, or the bolt is drawn for the
        // wrong background.
        for name in dark {
            let image = MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true)
            XCTAssertEqual(try inks(image, drawnAs: name), [.white, .yellowOnDark], name.rawValue)
        }
        for name in light {
            let image = MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true)
            XCTAssertEqual(try inks(image, drawnAs: name), [.black, .yellowOnLight], name.rawValue)
        }
    }

    func testOneImageRecoloursWhenTheMenuBarFlips() throws {
        // What `AppDelegate` relies on to build the mark once: the same instance, drawn again
        // under another appearance, redraws rather than replaying a cached first render. If
        // this ever stops holding, the fix is not to watch `effectiveAppearance` again.
        let image = MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true)
        XCTAssertEqual(try inks(image, drawnAs: .darkAqua), [.white, .yellowOnDark])
        XCTAssertEqual(try inks(image, drawnAs: .aqua), [.black, .yellowOnLight])
        XCTAssertEqual(try inks(image, drawnAs: .vibrantDark), [.white, .yellowOnDark])
    }

    func testTheIdleMarkStaysATemplate() {
        // macOS recolours a template for light, dark and highlighted menu bars by itself. The
        // charging mark can't be one (a template drops the yellow), so it must not be.
        XCTAssertTrue(MenuBarIcon.mouse(pointSize: 21, razerCutout: false).isTemplate)
        XCTAssertFalse(MenuBarIcon.mouse(pointSize: 21, razerCutout: false, charging: true).isTemplate)
    }
}
