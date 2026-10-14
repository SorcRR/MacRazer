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

    /// The appearance the app's windows use. Windows only follow light or dark: the glass and
    /// the green tint are the popover's. Nil follows macOS.
    var windowAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .dark, .razerGreen: return .darkAqua
        case .light: return .aqua
        }
    }
}

/// What the popover actually looks like once the theme, the glass switch and the system's
/// light or dark mode are combined. One case per mockup.
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
    var backdropRGBA: (red: Double, green: Double, blue: Double, alpha: Double)? {
        switch self {
        case .lightGlass, .darkGlass: return nil
        case .greenGlass: return (0x10 / 255, 0x3A / 255, 0x14 / 255, 0.35)
        case .solidLight: return (0xF5 / 255, 0xF5 / 255, 0xF7 / 255, 1)
        case .solidDark: return (0x1C / 255, 0x1C / 255, 0x1E / 255, 1)
        case .solidGreen: return (0x0F / 255, 0x1A / 255, 0x11 / 255, 1)
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
        glass = defaults.object(forKey: Self.glassKey) as? Bool ?? true
    }

    func look(systemIsDark: Bool) -> PopoverLook {
        PopoverLook.resolve(theme: theme, glass: glass, systemIsDark: systemIsDark)
    }

    // MARK: Windows

    private let windows = NSHashTable<NSWindow>.weakObjects()

    /// Gives a window the theme's light or dark appearance and keeps it updated when the
    /// setting changes.
    func track(_ window: NSWindow) {
        windows.add(window)
        Self.apply(theme, to: window)
    }

    /// Re-applies a theme to every tracked window. Takes the theme rather than reading
    /// `theme`, because the owner calls this from a `$theme` subscriber, which runs before the
    /// property itself has changed.
    func applyToWindows(theme: PopoverTheme) {
        for window in windows.allObjects { Self.apply(theme, to: window) }
    }

    private static func apply(_ theme: PopoverTheme, to window: NSWindow) {
        window.appearance = theme.windowAppearanceName.flatMap(NSAppearance.init(named:))
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Paints the solid colour (or the green tint) behind the popover's content.
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
