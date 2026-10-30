// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit
import Combine

/// The theme picked in Settings › Appearance.
enum PopoverTheme: String, CaseIterable, Identifiable {
    case system, dark, light, razerGreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        case .razerGreen: return "Razer Green"
        }
    }
}

/// What the popover and the app's windows actually look like once the theme, the glass switch
/// and the system's light or dark mode are combined. One case per mockup.
enum PopoverLook: Equatable, CaseIterable {
    case lightGlass, darkGlass, greenGlass
    case solidLight, solidDark, solidGreen

    /// Every combination in one place, so the popover, its arrow and the tests can't disagree.
    /// Razer Green is always dark: a light green tint looks washed out.
    static func resolve(theme: PopoverTheme, glass: Bool, systemIsDark: Bool) -> PopoverLook {
        switch theme {
        case .system: return systemIsDark ? (glass ? .darkGlass : .solidDark) : (glass ? .lightGlass : .solidLight)
        case .dark: return glass ? .darkGlass : .solidDark
        case .light: return glass ? .lightGlass : .solidLight
        case .razerGreen: return glass ? .greenGlass : .solidGreen
        }
    }

    var isDark: Bool {
        switch self {
        case .lightGlass, .solidLight: return false
        case .darkGlass, .greenGlass, .solidDark, .solidGreen: return true
        }
    }

    var isGlass: Bool {
        switch self {
        case .lightGlass, .darkGlass, .greenGlass: return true
        case .solidLight, .solidDark, .solidGreen: return false
        }
    }

    /// Whether the thin green edge goes round the popover.
    var hasGreenEdge: Bool { self == .greenGlass }

    /// What's painted over the popover's own material, arrow included. Nil leaves the native
    /// glass as it is. Solid looks are opaque; the green glass is a faint tint.
    var backdropColor: NSColor? {
        switch self {
        case .lightGlass, .darkGlass: return nil
        case .greenGlass: return NSColor(hex: 0x103A14, alpha: 0.35)
        case .solidLight: return NSColor(hex: 0xF5F5F7)
        case .solidDark: return NSColor(hex: 0x1C1C1E)
        case .solidGreen: return NSColor(hex: 0x0F1A11)
        }
    }

    var appearanceName: NSAppearance.Name { isDark ? .darkAqua : .aqua }
}

/// The Appearance settings, stored in UserDefaults. Shared by the Settings window, which
/// edits them, and the app delegate, which applies them to the popover and the windows.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let themeKey = "appearance.theme"
    static let glassKey = "appearance.glass"

    /// The app's one instance. The window controllers reach it here rather than having it
    /// threaded through every initializer; tests make their own with a scratch defaults suite.
    static let shared = AppearanceSettings()

    private let defaults: UserDefaults

    @Published var theme: PopoverTheme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }
    @Published var glass: Bool {
        didSet { defaults.set(glass, forKey: Self.glassKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An unknown stored value (a theme removed in a later version) falls back to System
        // rather than failing.
        theme = defaults.string(forKey: Self.themeKey).flatMap(PopoverTheme.init(rawValue:)) ?? .system
        glass = defaults.object(forKey: Self.glassKey) as? Bool ?? false
    }

    func look(systemIsDark: Bool) -> PopoverLook {
        PopoverLook.resolve(theme: theme, glass: glass, systemIsDark: systemIsDark)
    }

    // MARK: Windows

    private let windows = NSHashTable<NSWindow>.weakObjects()
    /// The look last given to the windows, so a window opened later matches them.
    private var windowLook: PopoverLook?

    /// Gives a window the current look (glass or solid, light, dark or green) and keeps it
    /// updated when the setting or the system's light or dark mode changes.
    func track(_ window: NSWindow) {
        windows.add(window)
        let look = windowLook ?? look(systemIsDark: NSApplication.shared.effectiveAppearance.isDark)
        WindowBackdrop.apply(look, to: window)
    }

    /// Re-applies a look to every tracked window. Takes the look rather than working it out
    /// from `theme`, because the owner calls this from a `$theme` subscriber, which runs before
    /// the property itself has changed.
    func applyToWindows(_ look: PopoverLook) {
        windowLook = look
        for window in windows.allObjects { WindowBackdrop.apply(look, to: window) }
    }
}

/// Puts a `PopoverLook` on an ordinary window: the same glass, solid colour or green tint as
/// the popover, so Settings and the other windows match it.
///
/// Like the popover's backdrop, the glass and the tint sit in the window's frame view, just
/// under the content, so they also cover the title bar.
@MainActor
enum WindowBackdrop {
    private static let glassID = NSUserInterfaceItemIdentifier("MacRazer.windowGlass")
    private static let tintID = NSUserInterfaceItemIdentifier("MacRazer.windowTint")

    static func apply(_ look: PopoverLook, to window: NSWindow) {
        window.appearance = NSAppearance(named: look.appearanceName)
        // The title bar shows whatever is behind it, so it matches the rest of the window
        // instead of drawing its own grey strip.
        window.titlebarAppearsTransparent = true
        let (glass, tint) = layers(in: window)
        if look.isGlass {
            window.isOpaque = false
            window.backgroundColor = .clear
            glass?.isHidden = false
            tint?.fill = look.backdropColor
        } else {
            window.isOpaque = true
            window.backgroundColor = look.backdropColor
            glass?.isHidden = true
            tint?.fill = nil
        }
    }

    /// The window's glass and tint views, added the first time.
    private static func layers(in window: NSWindow) -> (NSVisualEffectView?, PopoverBackdropView?) {
        guard let content = window.contentView, let frameView = content.superview else { return (nil, nil) }
        if let glass = frameView.subviews.first(where: { $0.identifier == glassID }) as? NSVisualEffectView,
           let tint = frameView.subviews.first(where: { $0.identifier == tintID }) as? PopoverBackdropView {
            return (glass, tint)
        }
        let glass = NSVisualEffectView(frame: frameView.bounds)
        glass.identifier = glassID
        // The popover's own material, so a window and the popover read as the same glass.
        glass.material = .popover
        glass.blendingMode = .behindWindow
        // Stay glass when the window isn't key, rather than going flat grey.
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        let tint = PopoverBackdropView(frame: frameView.bounds)
        tint.identifier = tintID
        tint.autoresizingMask = [.width, .height]
        frameView.addSubview(glass, positioned: .below, relativeTo: content)
        frameView.addSubview(tint, positioned: .below, relativeTo: content)
        return (glass, tint)
    }
}

extension NSColor {
    /// An sRGB colour from `0xRRGGBB`, the way the mockups and the docs write them.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Paints the solid colour (or the green tint) behind the popover's content. `WindowBackdrop`
/// reuses it as the green tint on the app's windows.
///
/// It sits in the popover's frame view rather than in SwiftUI, because the arrow is drawn by
/// that frame view, outside the content. A SwiftUI background would leave the arrow glass
/// while the body went solid. The frame view clips its subviews to the popover's outline,
/// arrow included, so filling the whole bounds fills exactly the popover.
final class PopoverBackdropView: NSView {
    var fill: NSColor? {
        didSet { isHidden = fill == nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    /// Clicks go to the content, never to the backdrop.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
