// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import XCTest
@testable import MacRazer

final class DpiCycleSoftwareBridgeTests: XCTestCase {
    private final class Output { var actions: [RemapAction] = [] }
    private func withRemapper(_ body: (ButtonRemapper, Output, UserDefaults) -> Void) {
        let suite = "DpiBridgeTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let output = Output()
        let remapper = ButtonRemapper(defaults: defaults, actionEmitter: { output.actions.append($0) })
        remapper.setActiveDevice("00ba")
        body(remapper, output, defaults)
    }

    private func passes(_ remapper: ButtonRemapper, down: Bool = true, key: CGKeyCode = 90,
                        flags: CGEventFlags = [], repeatKey: Bool = false) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return remapper.handle(type: down ? .keyDown : .keyUp, event: event) != nil
    }

    func testOnlyVerifiedBridgeEmitsOneActionAndConsumesItsMatchingRelease() {
        withRemapper { remapper, output, _ in
            let media = RemapAction.mediaKey(code: 16, name: "Play / Pause")
            remapper.saveDpiSoftwareAction(media)
            XCTAssertTrue(passes(remapper), "no hardware readback yet")
            remapper.confirmDpiBridge(binding: .softwareBridge)
            XCTAssertFalse(passes(remapper))
            XCTAssertFalse(passes(remapper, repeatKey: true))
            XCTAssertEqual(output.actions, [media])
            XCTAssertEqual(remapper.lastDetectedButton, -1)
            XCTAssertEqual(ButtonRemapper.label(for: -1), "DPI Cycle")
            remapper.confirmDpiBridge(binding: nil)
            remapper.remappingPaused = true
            XCTAssertFalse(passes(remapper, down: false), "finish an already consumed press even after disconnect")
            XCTAssertTrue(passes(remapper, down: false), "unmatched release passes")
        }
    }

    func testKeyboardInputIsUntouchedWithoutAllBridgeConditions() {
        withRemapper { remapper, output, _ in
            remapper.confirmDpiBridge(binding: .softwareBridge)
            XCTAssertTrue(passes(remapper), "no configured software action")
            remapper.saveDpiSoftwareAction(.mediaKey(code: 7, name: "Mute"))
            XCTAssertTrue(passes(remapper, key: 8))
            XCTAssertTrue(passes(remapper, flags: .maskCommand))
            XCTAssertTrue(passes(remapper, key: 111), "F12 must remain available")
            remapper.remappingPaused = true
            XCTAssertTrue(passes(remapper))
            remapper.remappingPaused = false
            remapper.confirmDpiBridge(binding: .dpiCycle)
            XCTAssertTrue(passes(remapper))
            remapper.setActiveDevice("other")
            remapper.confirmDpiBridge(binding: .softwareBridge)
            XCTAssertTrue(passes(remapper))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testActionPersistsButHardwareConfirmationDoesNotSurviveADeviceChange() {
        withRemapper { remapper, _, defaults in
            remapper.saveDpiSoftwareAction(.doubleClick)
            let relaunched = ButtonRemapper(defaults: defaults, actionEmitter: { _ in })
            relaunched.setActiveDevice("00ba")
            XCTAssertEqual(relaunched.dpiCycleSoftwareAction, .doubleClick)
            XCTAssertFalse(relaunched.dpiBridgeBindingConfirmed)
            relaunched.confirmDpiBridge(binding: .softwareBridge)
            relaunched.setActiveDevice(nil)
            XCTAssertNil(relaunched.dpiCycleSoftwareAction)
            XCTAssertFalse(relaunched.dpiBridgeBindingConfirmed)
            relaunched.setActiveDevice("00ba")
            relaunched.saveDpiSoftwareAction(nil)
            let cleared = ButtonRemapper(defaults: defaults)
            cleared.setActiveDevice("00ba")
            XCTAssertNil(cleared.dpiCycleSoftwareAction)
        }
    }


    func testSavedSoftwareActionRestoresOnlyWhenVerifiedHardwareBindingReverts() {
        withRemapper { remapper, _, _ in
            remapper.saveDpiSoftwareAction(.mediaKey(code: 16, name: "Play / Pause"))
            XCTAssertTrue(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                           bluetooth: true, alreadyAttempted: false))
            XCTAssertTrue(remapper.shouldRestoreDpiBridge(binding: nil, connected: true,
                                                           bluetooth: true, alreadyAttempted: false))
            XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .softwareBridge, connected: true,
                                                            bluetooth: true, alreadyAttempted: false))
            XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: false,
                                                            bluetooth: true, alreadyAttempted: false))
            XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                            bluetooth: false, alreadyAttempted: false))
            XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                            bluetooth: true, alreadyAttempted: true))
            remapper.saveDpiSoftwareAction(nil)
            XCTAssertFalse(remapper.shouldRestoreDpiBridge(binding: .dpiCycle, connected: true,
                                                            bluetooth: true, alreadyAttempted: false))
        }
    }

    func testMouseOnlyTapDoesNotCountAsKeyboardCapture() {
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(0x6000000))
        XCTAssertFalse(ButtonRemapper.includesKeyboardEvents(0x6000400))
        XCTAssertTrue(ButtonRemapper.includesKeyboardEvents(0x6000C00))
    }

    func testSoftwareSignalHasTheExpectedFirmwarePacketAndPackedReadback() throws {
        XCTAssertEqual(Array(BLEVendorProtocol.dpiButtonPayload(for: .softwareBridge)),
                       [1, 0x60, 0, 2, 2, 0, 0x6F, 0, 0, 0])
        let packed = Data([0x60, 0, 2, 2, 2, 2, 0, 0, 0x6F, 0x6F, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try BLEVendorProtocol.parseDpiButtonBinding(packed), .softwareBridge)
    }
}
