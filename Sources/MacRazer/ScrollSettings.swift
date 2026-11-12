// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import CoreGraphics

/// App-wide preference and status. Used on the main thread, like the Settings window.
final class ScrollSettings: ObservableObject, @unchecked Sendable {
    static let shared = ScrollSettings()
    static let preferenceKey = "reverseScrollingOnRazerMice"
    @Published private(set) var enabled: Bool
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var eventTapAvailable = false
    let sourceIdentificationAvailable: Bool
    private let defaults: UserDefaults
    private let makeTap: (@escaping @Sendable (Bool) -> Void) -> any ScrollTapSession
    private var tap: (any ScrollTapSession)?
    private var generation = 0
    private var connected = false

    init(defaults: UserDefaults = .standard, sourceIdentificationAvailable: Bool? = nil,
         makeTap: @escaping (@escaping @Sendable (Bool) -> Void) -> any ScrollTapSession = { ScrollEventTap(onStatus: $0) }) {
        self.defaults = defaults
        self.makeTap = makeTap
        self.sourceIdentificationAvailable = sourceIdentificationAvailable ?? ScrollEventRouter().available
        enabled = defaults.bool(forKey: Self.preferenceKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        updateTap()
    }

    func update(connected: Bool, accessibilityGranted: Bool) {
        self.connected = connected
        self.accessibilityGranted = accessibilityGranted
        updateTap()
    }

    func refreshAccessibility(prompt: Bool = false) {
        accessibilityGranted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        updateTap()
    }

    func stop() {
        generation += 1
        tap?.stop()
        tap = nil
        eventTapAvailable = false
    }

    private func updateTap() {
        guard enabled && connected && accessibilityGranted && sourceIdentificationAvailable else { stop(); return }
        guard tap == nil else { return }
        generation += 1
        let current = generation
        let session = makeTap { [weak self] available in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.eventTapAvailable = available
                if !available { self.stop() }
            }
        }
        tap = session
        session.start()
    }

    deinit { tap?.stop() }
}

protocol ScrollTapSession: AnyObject, Sendable {
    func start()
    func stop()
}

/// A scroll-only tap on its own run loop. Cancellation also works before that loop starts.
/// Every tap and source is removed on the thread that installed it.
final class ScrollEventTap: ScrollTapSession, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private let router = ScrollEventRouter()
    private let onStatus: @Sendable (Bool) -> Void

    init(onStatus: @escaping @Sendable (Bool) -> Void) {
        self.onStatus = onStatus
    }

    func start() {
        lock.lock()
        guard !started && !cancelled else { lock.unlock(); return }
        started = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "MacRazer scrolling"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        cancelled = true
        let loop = runLoop
        lock.unlock()
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    private func run() {
        router.prepare()
        let loop = CFRunLoopGetCurrent()!
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        runLoop = loop
        lock.unlock()
        defer {
            lock.lock()
            runLoop = nil
            lock.unlock()
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ScrollEventTap>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = owner.port { CGEvent.tapEnable(tap: port, enable: true) }
                } else if type == .scrollWheel {
                    _ = owner.router.reverse(event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { onStatus(false); return }
        port = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onStatus(true)
        CFRunLoopRun()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
        port = nil
    }
}
