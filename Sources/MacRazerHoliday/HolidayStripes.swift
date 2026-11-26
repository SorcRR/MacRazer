// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// Diagonal candy-cane stripes. Bold for the battery bar; soft for the sliders, so a control
/// still reads as a control.
struct CandyStripes: View {
    var soft = false

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(soft ? HolidayColor.blush : .white))
            let band: CGFloat = soft ? 3 : 4, step = band * 2
            var x = -size.height
            while x < size.width + size.height {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height + band, y: 0))
                stripe.addLine(to: CGPoint(x: x + band, y: size.height))
                stripe.closeSubpath()
                ctx.fill(stripe, with: .color(soft ? HolidayColor.pink : HolidayColor.red))
                x += step
            }
        }
        .opacity(soft ? 0.85 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A native slider's filled track, as `controlSize(.small)` draws it: thin, centred, and
/// ending under the middle of the knob.
private let sliderTrackHeight: CGFloat = 4
private let sliderKnobWidth: CGFloat = 8

struct HolidaySliderStripes: ViewModifier {
    let fraction: Double
    @ObservedObject var holiday: Holiday

    func body(content: Content) -> some View {
        content.overlay {
            if holiday.isFestive {
                GeometryReader { geo in
                    let f = CGFloat(min(max(fraction, 0), 1))
                    let knobCentre = sliderKnobWidth / 2 + f * (geo.size.width - sliderKnobWidth)
                    // Stops at the knob's edge, so the knob stays on top.
                    let width = max(0, knobCentre - sliderKnobWidth / 2)
                    CandyStripes(soft: true)
                        .frame(width: width, height: sliderTrackHeight)
                        .clipShape(Capsule())
                        .position(x: width / 2, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

struct HolidayBarStripes: ViewModifier {
    let enabled: Bool
    @ObservedObject var holiday: Holiday

    func body(content: Content) -> some View {
        content.overlay {
            if enabled && holiday.isFestive { CandyStripes().clipShape(Capsule()) }
        }
    }
}

extension View {
    /// Soft candy stripes along a slider's filled track in December. `fraction` is how far
    /// along the knob is, 0 to 1. The plain slider whenever the decorations are off.
    public func holidaySliderStripes(_ fraction: Double) -> some View {
        modifier(HolidaySliderStripes(fraction: fraction, holiday: .shared))
    }

    /// Candy-cane stripes over a level bar's fill in December, when `enabled`: the app turns
    /// them off when the bar's own colour is a warning. The plain bar whenever they're off.
    public func holidayBarStripes(_ enabled: Bool = true) -> some View {
        modifier(HolidayBarStripes(enabled: enabled, holiday: .shared))
    }
}
