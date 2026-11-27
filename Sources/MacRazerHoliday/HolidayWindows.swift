// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine
import SwiftUI

/// Whether a window is actually on screen: open and not hidden behind others. Drives the
/// animations, so nothing moves in a window no one can see.
@MainActor
final class WindowVisibility: ObservableObject {
    @Published private(set) var visible = false
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    var changed: ((Bool) -> Void)?

    func watch(_ window: NSWindow?) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window
        guard let window else { update(false); return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            let closing = name == NSWindow.willCloseNotification
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if closing { self?.update(false) } else { self?.recheck() }
                }
            })
        }
        recheck()
    }

    private func recheck() {
        guard let window else { return update(false) }
        update(window.isVisible && window.occlusionState.contains(.visible))
    }

    private func update(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        changed?(value)
    }
}

/// Finds the window a SwiftUI view is in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Reader { Reader(found: found) }
    func updateNSView(_ nsView: Reader, context: Context) {}

    final class Reader: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); found(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Tells the game when a window with peek spots is on screen.
private struct HolidaySurfaceTracker: ViewModifier {
    let surface: HolidaySurface
    @StateObject private var visibility = WindowVisibility()

    func body(content: Content) -> some View {
        content.background(WindowReader { window in
            visibility.changed = { HolidayGame.shared.setVisible(surface, $0) }
            visibility.watch(window)
        })
    }
}

extension View {
    /// Marks a window's root view as a place the game plays, so it runs while the window is on
    /// screen and stops when it's closed or hidden.
    public func holidayGameSurface(_ surface: HolidaySurface) -> some View {
        modifier(HolidaySurfaceTracker(surface: surface))
    }
}

/// The windows' background while the decorations are on: faint candy canes scattered behind
/// the content and a little snow. It sits under the window's content and takes no clicks.
public enum HolidayWindowDecor {
    private static let id = NSUserInterfaceItemIdentifier("MacRazer.holidayDecor")

    /// Adds the background to a window, once. It shows and hides itself with the season.
    @MainActor
    public static func attach(to window: NSWindow) {
        guard let content = window.contentView, let frameView = content.superview,
              !frameView.subviews.contains(where: { $0.identifier == id }) else { return }
        let visibility = WindowVisibility()
        let host = PassThroughHostingView(rootView: WindowBackground(visibility: visibility))
        host.identifier = id
        host.frame = frameView.bounds
        host.autoresizingMask = [.width, .height]
        frameView.addSubview(host, positioned: .below, relativeTo: content)
        visibility.watch(window)
    }

    private final class PassThroughHostingView<V: View>: NSHostingView<V> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private struct WindowBackground: View {
        @ObservedObject var visibility: WindowVisibility
        @ObservedObject private var holiday = Holiday.shared

        var body: some View {
            if holiday.isFestive {
                ZStack {
                    CandyCanes()
                    SnowLayer(count: 30, animating: visibility.visible && !holiday.stillMode)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Candy canes scattered at random angles, faint enough to read over.
struct CandyCanes: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 17)
            let count = Int(size.width * size.height / 9000)
            for _ in 0..<max(count, 6) {
                var cane = ctx
                cane.opacity = 0.13
                cane.translateBy(x: rng.next() * size.width, y: rng.next() * size.height)
                cane.rotate(by: .degrees(rng.next() * 360))
                let scale = 0.7 + rng.next() * 0.6
                cane.scaleBy(x: scale, y: scale)
                var path = Path()
                path.move(to: CGPoint(x: 4, y: 22))
                path.addLine(to: CGPoint(x: 4, y: 7))
                path.addArc(center: CGPoint(x: 0, y: 7), radius: 4, startAngle: .zero, endAngle: .degrees(180), clockwise: true)
                cane.stroke(path, with: .color(Color(hex: 0xF7C1C1)), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
                cane.stroke(path, with: .color(HolidayColor.red), style: StrokeStyle(lineWidth: 3.4, dash: [2.6, 2.6]))
            }
        }
    }
}

/// The menu bar's tree, a template image like the app's own icons so it takes the menu bar's
/// colour. Only for the normal state: charging, a low battery and no mouse keep the real icon.
public enum HolidayMenuBarIcon {
    @MainActor
    public static func tree(pointSize s: CGFloat = 21, star: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
            let k = s / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
            NSColor.black.setFill()
            let tree = NSBezierPath()
            tree.move(to: p(12, star ? 6 : 3))
            for (x, y) in [(17, 10), (14.6, 10), (18.6, 15), (15.6, 15), (19.8, 20), (4.2, 20), (8.4, 15), (5.4, 15), (9.4, 10), (7, 10)] as [(CGFloat, CGFloat)] {
                tree.line(to: p(x, y))
            }
            tree.close()
            tree.fill()
            NSBezierPath(rect: NSRect(x: 10.8 * k, y: 20 * k, width: 2.4 * k, height: 3 * k)).fill()
            if star {
                let starPath = NSBezierPath()
                for i in 0..<10 {
                    let a = -Double.pi / 2 + Double(i) * .pi / 5, r: CGFloat = i.isMultiple(of: 2) ? 3 : 1.3
                    let pt = p(12 + r * cos(a), 3.4 + r * sin(a))
                    if i == 0 { starPath.move(to: pt) } else { starPath.line(to: pt) }
                }
                starPath.close()
                starPath.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacRazer"
        return image
    }
}
