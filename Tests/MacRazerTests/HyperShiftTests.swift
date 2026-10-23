// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import XCTest
@testable import MacRazer

final class HyperShiftTests: XCTestCase {
    private var emitted: [RemapAction] = []

    /// MacRazer's own HyperShift, on a mouse without an onboard layer (the wired Basilisk V3);
    /// `pid` 0x00E3 is the V4 Pro, whose HyperShift lives in the mouse.
    private func remapper(_ suite: String = #function, pid: Int = 0x0099) -> ButtonRemapper {
        let name = "MacRazerTests.\(suite)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let r = ButtonRemapper(defaults: defaults) { [weak self] in self?.emitted.append($0) }
        r.setActiveDevice("MOUSE", deviceID: pid)
        return r
    }

    private let copy = RemapAction.keystroke(keyCode: 8, modifiers: 0, name: "Copy")
    private let paste = RemapAction.keystroke(keyCode: 9, modifiers: 0, name: "Paste")

    private func click(_ r: ButtonRemapper, _ button: Int64, down: Bool) -> Bool {
        let event = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp,
                            mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return r.handle(type: down ? .otherMouseDown : .otherMouseUp, event: event) != nil
    }

    func testHeldShiftKeySwitchesToTheSecondLayer() {
        let r = remapper()
        let middle = 4, back = 3
        r.setAction(.hyperShift, for: middle)
        r.setAction(copy, for: back)
        r.setAction(paste, for: ButtonRemapper.hyperShiftKey(back))

        XCTAssertFalse(click(r, 3, down: true))
        XCTAssertFalse(click(r, 3, down: false))
        XCTAssertFalse(click(r, 4, down: true))
        XCTAssertTrue(r.hyperShiftHeld)
        XCTAssertFalse(click(r, 3, down: true))
        XCTAssertFalse(click(r, 3, down: false))
        XCTAssertFalse(click(r, 4, down: false))
        XCTAssertFalse(r.hyperShiftHeld)
        XCTAssertEqual(emitted, [copy, paste], "the shift key itself emits nothing")
    }

    func testUnmappedLayerSlotFallsBackToTheStandardJob() {
        let r = remapper()
        r.setAction(.hyperShift, for: 4)
        XCTAssertFalse(click(r, 4, down: true))
        // Nothing mapped on either layer: the button's own click goes through.
        XCTAssertTrue(click(r, 2, down: true))
        r.setAction(copy, for: 2)
        XCTAssertEqual(r.activeAction(for: 2), copy)
    }

    func testLayerSlotsStayOutOfTheButtonListAndHaveReadableNames() {
        let key = ButtonRemapper.hyperShiftKey(HardwareButton.sideFront.rawValue)
        XCTAssertTrue(ButtonRemapper.isHyperShiftKey(key))
        for id in HardwareButton.allCases.map(\.rawValue) + [-1, 0, 2, 3, 4, 31] {
            XCTAssertFalse(ButtonRemapper.isHyperShiftKey(id))
        }
        XCTAssertEqual(remapper(pid: 0x00E3).displayLabel(for: key), "HyperShift + Side Front")
    }

    func testV4ProSideButtonsAreListedByTheirPlace() {
        let r = remapper(pid: 0x00E3)
        XCTAssertTrue(r.suggestedButtons.isSuperset(of: [3, 4]))
        XCTAssertEqual(r.displayLabel(for: 2), "Scroll Click")
        XCTAssertEqual(r.displayLabel(for: 3), "Side Back")
        XCTAssertEqual(r.displayLabel(for: 4), "Side Middle")
        XCTAssertEqual(ButtonRemapper.label(for: HardwareButton.wheelMode.rawValue), "Scroll Mode")
        XCTAssertEqual(ButtonRemapper.label(for: HardwareButton.tiltLeft.rawValue), "Scroll Left")
        XCTAssertEqual(ButtonRemapper.label(for: HardwareButton.tiltRight.rawValue), "Scroll Right")
    }

    // MARK: Polling rate 2

    func testV4ProUsesPollingRate2() {
        XCTAssertEqual(RazerCommands.supportedPollingRates(pid: 0x00E3), [125, 250, 500, 1000, 2000, 4000, 8000])
        XCTAssertEqual(RazerCommands.supportedPollingRates(pid: 0x00B9), RazerCommands.supportedPollingRates)

        let wired = RazerCommands.setPollingRateReports(8000, pid: 0x00E2)
        XCTAssertEqual(wired.map { [$0.commandClass, $0.commandId, $0.dataSize, $0.arguments[0], $0.arguments[1]] },
                       [[0x00, 0x40, 0x02, 0x00, 0x01]])
        let dongle = RazerCommands.setPollingRateReports(1000, pid: 0x00E3)
        XCTAssertEqual(dongle.map { [$0.arguments[0], $0.arguments[1]] }, [[0x00, 0x08], [0x01, 0x08]])
    }

    func testPollingRate2ReadDecodesTheProbedAnswer() {
        var reply = RazerReport(commandClass: 0x00, commandId: 0xC0, dataSize: 0x01)
        reply.arguments[1] = 0x08 // the V4 Pro's own answer: `00 08`
        let read = RazerCommands.pollingRateRead(pid: 0x00E3)
        XCTAssertEqual(read.report.commandId, 0xC0)
        XCTAssertEqual(read.parse(reply), 1000)
        reply.arguments[1] = 0x01
        XCTAssertEqual(read.parse(reply), 8000)
    }
}
