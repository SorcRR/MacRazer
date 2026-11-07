// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import SwiftUI

/// Scrolling over a popover slider moves it: SwiftUI's `Slider` ignores the scroll wheel on
/// macOS. Up (a wheel rolled away, or two fingers pushed up) raises the value, whatever the
/// natural-scrolling setting. Horizontal scrolls pass through untouched.
enum SliderScroll {
    /// A trackpad scroll this many points long crosses the whole slider.
    static let pointsPerSpan = 300.0
    /// How long scrolling has to stop before the value goes to the device. A wheel has no
    /// "let go" the way a drag does, and one write per notch would flood the mouse.
    static let commitDelay = 0.3

    /// How far one wheel notch moves a slider: 1% of its range, rounded to the slider's own
    /// `snap` (the step a drag moves in) and never finer than it. Brightness and Wave speed
    /// move exactly 1%; DPI 250 on a 26,000 range (its 50 grid); the sleep timer 15 s, its
    /// smallest step, though 1% of it would be 8.4 s.
    static func notch(range: ClosedRange<Double>, snap: Double) -> Double {
        let onePercent = (range.upperBound - range.lowerBound) / 100
        guard snap > 0 else { return onePercent }
        return max(snap, (onePercent / snap).rounded() * snap)
    }

    /// The value after one wheel notch: one `notch` up or down, however hard the wheel was
    /// flicked (acceleration would make a notch jump unevenly), on the slider's `snap` grid
    /// and kept in `range`. `delta` is positive for up.
    static func notched(_ value: Double, delta: Double, range: ClosedRange<Double>,
                        notch: Double, snap: Double) -> Double {
        guard delta != 0 else { return value }
        return clamp(snapped(value + (delta > 0 ? notch : -notch), to: snap), range)
    }

    /// A trackpad scroll: its points add up in `carried` until they make whole notches, so a
    /// swipe moves in proportion (`pointsPerSpan` crosses the slider) however it is split
    /// into events. Returns the new value and the points still short of a notch.
    static func swiped(_ value: Double, delta: Double, carried: Double, range: ClosedRange<Double>,
                       notch: Double, snap: Double) -> (value: Double, carried: Double) {
        let span = range.upperBound - range.lowerBound
        guard notch > 0, span > 0 else { return (value, 0) }
        let pointsPerNotch = pointsPerSpan * notch / span
        let total = carried + delta
        let notches = (total / pointsPerNotch).rounded(.towardZero)
        guard notches != 0 else { return (value, total) }
        let moved = clamp(snapped(value + notches * notch, to: snap), range)
        // At an end, drop what's left so turning back responds at once.
        let rest = moved == value ? 0 : total - notches * pointsPerNotch
        return (moved, rest)
    }

    /// Whole multiples of `snap`, not steps from the low end: DPI lands on 1750, 2000 rather
    /// than off the 100 floor. No snap leaves the value as it is.
    private static func snapped(_ v: Double, to snap: Double) -> Double {
        snap > 0 ? (v / snap).rounded() * snap : v
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }
}

/// Holds the scroll monitor while the pointer is over one slider, the trackpad points not
/// yet a step, and the pending commit.
@MainActor
private final class SliderScrollTracker: ObservableObject {
    private var monitor: Any?
    private var pendingCommit: DispatchWorkItem?
    /// The window the slider was hovered in. Events from anywhere else pass through, and
    /// once it's hidden (the popover closed with the pointer still on the slider, so no
    /// hover exit came) the monitor removes itself.
    private weak var window: NSWindow?
    var carried = 0.0
    /// Replaced on every render of the slider, so the monitor always uses its current range
    /// and commit (and whatever view state the commit reads), not the ones from when the
    /// pointer arrived. Not published: setting it re-renders nothing.
    var handle: ((NSEvent) -> Bool)?

    func start() {
        guard monitor == nil else { return }
        // The front-most window under the pointer, by on-screen stacking rather than list order.
        window = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: NSEvent.mouseLocation,
                                                                      belowWindowWithWindowNumber: 0))
        carried = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread. The verdict crosses back, not the event.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                guard let window = self.window, window.isVisible, event.window === window else {
                    self.stop()
                    self.flushCommit()
                    return false
                }
                return self.handle?(event) == true
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
    }

    func scheduleCommit(_ commit: @escaping () -> Void) {
        pendingCommit?.cancel()
        // Clears itself when it runs, so a later flush can't send the same value again.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pendingCommit = nil }
            commit()
        }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SliderScroll.commitDelay, execute: work)
    }

    /// The pointer left mid-scroll: send now rather than lose the change.
    func flushCommit() {
        guard let work = pendingCommit else { return }
        pendingCommit = nil
        work.cancel()
        work.perform()
    }
}

private struct SliderScrollModifier: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let snap: Double
    let onCommit: (Double) -> Void
    @StateObject private var tracker = SliderScrollTracker()
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        tracker.handle = handle
        return content
            .onHover { inside in
                if inside && isEnabled {
                    tracker.start()
                } else {
                    finish()
                }
            }
            // Greyed out under the pointer (the mouse went offline): stop taking scrolls.
            .onChange(of: isEnabled) { _, enabled in if !enabled { finish() } }
            .onDisappear { finish() }
    }

    private func finish() {
        tracker.stop()
        tracker.flushCommit()
    }

    /// True when the event was for this slider (and is consumed).
    private func handle(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dy) > abs(dx), dy != 0 else { return false }
        // Momentum after a trackpad flick keeps coming for a while; swallow it rather than
        // run the slider on past where the fingers stopped.
        guard event.momentumPhase.isEmpty else { return true }
        let up = event.isDirectionInvertedFromDevice ? -dy : dy
        let notch = SliderScroll.notch(range: range, snap: snap)
        let next: Double
        if event.hasPreciseScrollingDeltas {
            let swiped = SliderScroll.swiped(value, delta: up, carried: tracker.carried, range: range,
                                             notch: notch, snap: snap)
            tracker.carried = swiped.carried
            next = swiped.value
        } else {
            next = SliderScroll.notched(value, delta: up, range: range, notch: notch, snap: snap)
        }
        if next != value {
            value = next
            let binding = $value
            let commit = onCommit
            tracker.scheduleCommit { commit(binding.wrappedValue) }
        }
        return true
    }
}

extension View {
    /// Lets the scroll wheel or a trackpad move this slider while the pointer is over it, 1%
    /// of `range` a notch (`SliderScroll.notch`). `snap` is the slider's own step, 0 for
    /// none; `onCommit` runs once scrolling stops, as a drag's end does.
    func scrollAdjusts(_ value: Binding<Double>, in range: ClosedRange<Double>, snap: Double = 0,
                       onCommit: @escaping (Double) -> Void) -> some View {
        modifier(SliderScrollModifier(value: value, range: range, snap: snap, onCommit: onCommit))
    }
}
