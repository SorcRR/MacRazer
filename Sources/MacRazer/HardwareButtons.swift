// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Controls of a mouse that aren't CGEvent buttons: the macOS tap never sees them, and they
/// are remapped only by saving the remap in the mouse (`OnboardButtons`). Named after the
/// Basilisk V4 Pro, whose controls these are.
///
/// The raw values are the ids the remap table stores them under. They are negative so they
/// can never collide with a CGEvent button number (-1 is already the Bluetooth DPI Cycle).
enum HardwareButton: Int, CaseIterable, Sendable {
    case scrollUp = -18
    case scrollDown = -17
    case dpiCycle = -16
    case wheelMode = -15
    case sideFront = -14
    case sideTrigger = -13
    case leftClickSide = -12
    case tiltLeft = -11
    case tiltRight = -10

    var label: String {
        switch self {
        case .scrollUp: return "Scroll Up"
        case .scrollDown: return "Scroll Down"
        case .dpiCycle: return "DPI"
        case .wheelMode: return "Scroll Mode"
        case .sideFront: return "Side Front"
        case .sideTrigger: return "Side Trigger"
        case .leftClickSide: return "Left Index"
        case .tiltLeft: return "Scroll Left"
        case .tiltRight: return "Scroll Right"
        }
    }
}
