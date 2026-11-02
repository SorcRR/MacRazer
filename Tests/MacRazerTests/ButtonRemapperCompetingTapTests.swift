// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics
import XCTest
@testable import MacRazer

/// Another app's event tap can drop a side-button click before MacRazer's sees it, and then
/// the button never shows up on Configure Buttons. Only a tap that can actually drop one counts.
final class ButtonRemapperCompetingTapTests: XCTestCase {
    private let own: pid_t = 100
    private let otherMouse = CGEventMask(1) << CGEventType.otherMouseDown.rawValue
    private let keyDown = CGEventMask(1) << CGEventType.keyDown.rawValue

    private func tap(_ pid: pid_t, tapped: pid_t = 0, enabled: Bool = true, listenOnly: Bool = false,
                     events: CGEventMask? = nil) -> ButtonRemapper.TapEntry {
        .init(pid: pid, tappedPID: tapped, enabled: enabled, listenOnly: listenOnly,
              eventsOfInterest: events ?? otherMouse)
    }

    func testAFilteringTapOnOtherMouseCompetes() {
        XCTAssertEqual(ButtonRemapper.competingTapPIDs([tap(200)], ownPID: own), [200])
    }

    func testTapsThatCannotDropAClickAreLeftOut() {
        let taps = [
            tap(own),                         // ours
            tap(201, enabled: false),
            tap(202, listenOnly: true),       // can only watch
            tap(203, events: keyDown),        // keyboard only
            tap(204, tapped: 999),            // filters one app's events, not the session's
        ]
        XCTAssertEqual(ButtonRemapper.competingTapPIDs(taps, ownPID: own), [])
    }

    func testAnAppWithSeveralTapsIsNamedOnce() {
        let taps = [tap(300), tap(301), tap(300, events: otherMouse | keyDown)]
        XCTAssertEqual(ButtonRemapper.competingTapPIDs(taps, ownPID: own), [300, 301])
    }

    func testAHelperIsNamedByTheAppAroundIt() {
        XCTAssertEqual(ButtonRemapper.appName(executablePath:
            "/Applications/Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app/Contents/MacOS/Mac Mouse Fix Helper"),
            "Mac Mouse Fix")
        XCTAssertNil(ButtonRemapper.appName(executablePath: "/usr/libexec/universalaccessd"))
        XCTAssertNil(ButtonRemapper.appName(executablePath: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
        XCTAssertNil(ButtonRemapper.appName(executablePath: "/opt/homebrew/bin/skhd"))
    }

    func testAHelperInsideAnAppleAppIsLeftOut() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/Applications/Safari.app"))
        XCTAssertNil(ButtonRemapper.appName(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    func testTheNoteNamesEachApp() {
        XCTAssertEqual(RemapView.competingAppsText(["Mac Mouse Fix"]),
                       "If a side button doesn't show up here when you press it, Mac Mouse Fix may be "
                       + "taking its clicks. Quit it and try again.")
        XCTAssertTrue(RemapView.competingAppsText(["SteerMouse", "BetterMouse"]).hasSuffix("Quit them and try again."))
    }

    private func press(_ remapper: ButtonRemapper, button: Int) {
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                            mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        _ = remapper.handle(type: .otherMouseDown, event: event)
    }

    /// A filtering tap may pass every click on, so once a side button gets through, nothing
    /// is taking them. The wheel click says nothing: it's the one Henry's mouse still sent.
    func testASideButtonGettingThroughEndsTheNote() {
        let r = ButtonRemapper(defaults: UserDefaults(suiteName: "competing-tap-\(UUID())")!)
        press(r, button: 2)
        XCTAssertFalse(r.sideButtonDetected)
        press(r, button: 3)
        XCTAssertTrue(r.sideButtonDetected)
        r.setActiveDevice("another-mouse")
        XCTAssertFalse(r.sideButtonDetected, "detection is per mouse")
    }
}
