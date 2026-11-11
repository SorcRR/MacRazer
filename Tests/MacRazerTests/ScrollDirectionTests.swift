// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
import CoreGraphics
import AppKit
@testable import MacRazer

final class ScrollDirectionTests: XCTestCase {
    func testRazerMiceMatchWithoutPerUnitIdentity() {
        XCTAssertTrue(ScrollDevice(vendorID: 0x1532, productID: 0x00EA).isRazerMouse)
        XCTAssertTrue(ScrollDevice(vendorID: 0x1532, productID: 0x00DB).isRazerMouse)
        XCTAssertTrue(ScrollDevice(vendorID: 0x1532, productID: 0xFFFF, mouseUsage: true).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: 0x046D, productID: 0x00EA, mouseUsage: true).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: 0x05AC, productID: 0x0324, mouseUsage: true).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: 0x1532, productID: 0x022A).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: 0, productID: 0).isRazerMouse)
    }

    func testKnownBluetoothMouseNeedsNoHIDSerial() {
        XCTAssertTrue(ScrollDevice(vendorID: Razer.vendorId, productID: 0x00BA,
                                  name: "Basilisk V3 X HS", bluetooth: true).isRazerMouse)
        XCTAssertTrue(ScrollDevice(vendorID: BLEProtocol.vendorId, productID: 0x00BA,
                                  name: "Basilisk V3 X HS", bluetooth: true).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: 0x05AC, productID: 0x00BA,
                                   name: "Basilisk V3 X HS", bluetooth: true).isRazerMouse)
        XCTAssertFalse(ScrollDevice(vendorID: BLEProtocol.vendorId, productID: 0xFFFF,
                                   name: "Razer Keyboard", bluetooth: true).isRazerMouse)
    }

    func testAllScrollRepresentationsReverseWithoutChangingEventMetadata() throws {
        let event = try scrollEvent()
        event.flags = .maskShift
        event.timestamp = 12345
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        event.setIntegerValueField(.eventSourceUserData, value: 123)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        ScrollDirection.reverse(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 4)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -17)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 24)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), -1.5)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), 2.25)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), continuous)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 2)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 123)
        XCTAssertEqual(event.flags, .maskShift)
        XCTAssertEqual(event.timestamp, 12345)
        let native = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(native.scrollingDeltaX, 24)
        XCTAssertEqual(native.scrollingDeltaY, -17)
    }

    func testReversingTwiceRestoresTheOriginalValues() throws {
        let event = try scrollEvent()
        ScrollDirection.reverse(event)
        ScrollDirection.reverse(event)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), -4)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 17)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -24)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 1.5)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), -2.25)
    }

    func testAnEventWithoutDeviceMetadataIsNeverReversed() throws {
        let event = try scrollEvent()
        XCTAssertFalse(ScrollEventRouter().reverse(event))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 17)
    }

    private func scrollEvent() throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 2, wheel1: 3, wheel2: -4, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -4)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 1.5)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -2.25)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 17)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -24)
        return event
    }
}

final class ScrollSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "MacRazerTests-Scroll-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private final class FakeTap: ScrollTapSession, @unchecked Sendable {
        var starts = 0
        var stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    func testGlobalPreferencePersistsAcrossConnectionsAndRelaunch() {
        let settings = ScrollSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        settings.setEnabled(true)
        settings.update(connected: false, accessibilityGranted: false)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(ScrollSettings(defaults: defaults).enabled)
        settings.setEnabled(false)
        XCTAssertFalse(ScrollSettings(defaults: defaults).enabled)
    }

    func testTapOnlyRunsWhileEnabledConnectedAndPermitted() {
        var sessions: [FakeTap] = []
        let settings = ScrollSettings(defaults: defaults, sourceIdentificationAvailable: true, makeTap: { _ in
            let tap = FakeTap()
            sessions.append(tap)
            return tap
        })
        settings.update(connected: true, accessibilityGranted: true)
        XCTAssertTrue(sessions.isEmpty)
        settings.setEnabled(true)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].starts, 1)
        settings.update(connected: true, accessibilityGranted: true)
        XCTAssertEqual(sessions.count, 1, "Do not rebuild a running tap on unchanged state")
        settings.update(connected: false, accessibilityGranted: true)
        XCTAssertEqual(sessions[0].stops, 1)
        settings.update(connected: true, accessibilityGranted: true)
        XCTAssertEqual(sessions.count, 2)
        settings.update(connected: true, accessibilityGranted: false)
        XCTAssertEqual(sessions[1].stops, 1)
        settings.update(connected: true, accessibilityGranted: true)
        XCTAssertEqual(sessions.count, 3)
        settings.setEnabled(false)
        XCTAssertEqual(sessions[2].stops, 1)
    }

    func testUnavailableSourceAPIsNeverStartATap() {
        let settings = ScrollSettings(defaults: defaults, sourceIdentificationAvailable: false, makeTap: { _ in
            XCTFail("Unavailable APIs must leave scrolling alone")
            return FakeTap()
        })
        settings.setEnabled(true)
        settings.update(connected: true, accessibilityGranted: true)
        XCTAssertFalse(settings.eventTapAvailable)
    }

    func testUnknownSenderResolutionDoesNotBlockTheCaller() {
        let entered = expectation(description: "Lookup started")
        let released = DispatchSemaphore(value: 0)
        let sources = ScrollSources(resolve: { id in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = released.wait(timeout: .now() + 2)
            return id == 42
        })
        XCTAssertFalse(sources.contains(42))
        wait(for: [entered], timeout: 1)
        XCTAssertFalse(sources.contains(42), "A pending lookup must not block the callback")
        released.signal()
        let deadline = Date().addingTimeInterval(1)
        while !sources.contains(42), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(sources.contains(42))
    }

    func testSenderCanMatchAfterATemporaryLookupFailure() {
        final class Attempts: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func resolve(_ id: UInt64) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count > 1
            }
        }
        let attempts = Attempts()
        let sources = ScrollSources(retryInterval: 0.01, resolve: { attempts.resolve($0) })
        XCTAssertFalse(sources.contains(42))
        let deadline = Date().addingTimeInterval(1)
        while !sources.contains(42), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(sources.contains(42), "A temporary registry miss must not disable this sender forever")
    }

    func testStoppingBeforeTapStartupNeverInstallsIt() {
        let status = expectation(description: "Cancelled tap must not start")
        status.isInverted = true
        let tap = ScrollEventTap { _ in status.fulfill() }
        tap.stop()
        tap.start()
        wait(for: [status], timeout: 0.05)
    }
}
