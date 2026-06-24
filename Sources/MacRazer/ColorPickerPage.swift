// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// A clearly-labelled "‹ Back" button used by the popover sub-pages.
struct BackButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Back").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.primary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Inline hue/saturation colour wheel + brightness slider, shown as a sub-page of the popover.
/// Applies the colour to the mouse live (throttled) as you drag.
struct ColorPickerPage: View {
    @Binding var color: Color
    var onBack: () -> Void
    var onApply: (RGB) -> Void

    @State private var hue: Double = 0
    @State private var sat: Double = 1
    @State private var bri: Double = 1
    @State private var lastApply = Date.distantPast

    private let hueColors: [Color] = (0...6).map { Color(hue: Double($0) / 6.0, saturation: 1, brightness: 1) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                BackButton(action: onBack)
                Text("Colour").font(.system(size: 16, weight: .semibold))
                Spacer()
                Circle().fill(color).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
            wheel
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Slider(value: $bri, in: 0...1) { editing in apply(force: !editing) }
                    .tint(.razerGreen).controlSize(.small)
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFromColor)
    }

    private var wheel: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, 180)
            let r = side / 2
            let center = CGPoint(x: geo.size.width / 2, y: 90)
            ZStack {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: hueColors), center: .center))
                    .overlay(Circle().fill(RadialGradient(
                        gradient: Gradient(colors: [.white, .white.opacity(0)]),
                        center: .center, startRadius: 0, endRadius: r)))
                    .overlay(Circle().fill(.black.opacity(1 - bri)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .frame(width: side, height: side)
                Circle().stroke(.white, lineWidth: 2)
                    .frame(width: 15, height: 15)
                    .shadow(radius: 1)
                    .position(selectorPos(center: center, r: r))
            }
            .frame(width: geo.size.width, height: 180)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { update(location: $0.location, center: center, r: r) }
                .onEnded { _ in onApply(color.rgb) })
        }
        .frame(height: 180)
    }

    private func selectorPos(center: CGPoint, r: CGFloat) -> CGPoint {
        let angle = hue * 2 * .pi
        let dist = sat * r
        return CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist)
    }

    private func update(location: CGPoint, center: CGPoint, r: CGFloat) {
        let dx = location.x - center.x, dy = location.y - center.y
        var angle = atan2(dy, dx)
        if angle < 0 { angle += 2 * .pi }
        hue = angle / (2 * .pi)
        sat = min(hypot(dx, dy) / r, 1)
        apply(force: false)
    }

    private func apply(force: Bool) {
        color = Color(hue: hue, saturation: sat, brightness: max(bri, 0.001))
        let now = Date()
        if force || now.timeIntervalSince(lastApply) > 0.07 { // throttle live HID writes
            lastApply = now
            onApply(color.rgb)
        }
    }

    private func syncFromColor() {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h); sat = Double(s); bri = Double(b)
    }
}
