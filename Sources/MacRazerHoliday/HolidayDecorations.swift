// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// How much wider the popover gets on each side for the branches. The content inside keeps
/// its usual width; the popover grows around it.
public let holidayBranchWidth: CGFloat = 26
/// How much taller it gets at the top for the hanging star, from Christmas Day.
let holidayStarHeight: CGFloat = 28

/// Frames per second for everything that moves: plenty for twinkling and falling snow, and a
/// third of what a display would otherwise draw.
private let frameInterval = 1.0 / 20

/// A pine branch down one side, with a string of lights. The needles are drawn once; only the
/// lights redraw, a few times a second.
struct BranchStrip: View {
    enum Side { case leading, trailing }
    let side: Side
    let animating: Bool

    var body: some View {
        ZStack {
            Canvas { ctx, size in drawNeedles(ctx, size) }
            TimelineView(.animation(minimumInterval: frameInterval, paused: !animating)) { timeline in
                Canvas { ctx, size in
                    drawLights(ctx, size, t: animating ? timeline.date.timeIntervalSinceReferenceDate : 0)
                }
            }
        }
        .frame(width: holidayBranchWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stemX(_ y: CGFloat) -> CGFloat {
        let x = 8 + sin(y / 37) * 3
        return side == .leading ? x : holidayBranchWidth - x
    }

    private var direction: CGFloat { side == .leading ? 1 : -1 }

    private func drawNeedles(_ ctx: GraphicsContext, _ size: CGSize) {
        var rng = SeededRandom(seed: side == .leading ? 7 : 13)
        var stem = Path()
        stem.move(to: CGPoint(x: stemX(0), y: 0))
        for y in stride(from: 4, through: size.height, by: 4) { stem.addLine(to: CGPoint(x: stemX(y), y: y)) }
        ctx.stroke(stem, with: .color(HolidayColor.bark), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        for y in stride(from: 0, through: size.height, by: 2.4) {
            let x = stemX(y)
            for out in [1.0, -1.0] as [CGFloat] {
                let length = (out > 0 ? 12 : 6) + rng.next() * 6
                let angle = (20 + rng.next() * 50) * .pi / 180
                var needle = Path()
                needle.move(to: CGPoint(x: x, y: y))
                needle.addLine(to: CGPoint(x: x + direction * out * cos(angle) * length, y: y + sin(angle) * length * 0.9))
                let color = HolidayColor.needles[Int(rng.next() * 4.99)]
                ctx.stroke(needle, with: .color(color.opacity(0.92)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        }
    }

    private func drawLights(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        var rng = SeededRandom(seed: side == .leading ? 21 : 34)
        var wire = Path()
        let wireX = { (y: CGFloat) in stemX(y) + direction * (6 + sin(y / 19) * 3) }
        wire.move(to: CGPoint(x: wireX(0), y: 0))
        for y in stride(from: 4, through: size.height, by: 4) { wire.addLine(to: CGPoint(x: wireX(y), y: y)) }
        ctx.stroke(wire, with: .color(HolidayColor.ink.opacity(0.7)), lineWidth: 0.8)
        var y: CGFloat = 14, i = 0
        while y < size.height - 6 {
            let x = wireX(y), color = HolidayColor.lights[i % HolidayColor.lights.count]
            let speed = 1.2 + rng.next() * 1.6, phase = rng.next() * 6
            let on = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * (2 * .pi / speed) + phase))
            ctx.fill(Path(roundedRect: CGRect(x: x - 1.6, y: y - 5, width: 3.2, height: 2.6), cornerRadius: 0.6),
                     with: .color(Color(hex: 0x888780)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: y - 5, width: 11, height: 11)), with: .color(color.opacity(0.3 * on)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: y - 2.9, width: 5.2, height: 6.8)), with: .color(color.opacity(on)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.4, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.8 * on)))
            y += 26 + rng.next() * 10
            i += 1
        }
    }
}

/// Snow falling behind the content, with a little sideways drift.
struct SnowLayer: View {
    var count = 16
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !animating)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var rng = SeededRandom(seed: 99)
                for _ in 0..<count {
                    let x0 = rng.next() * size.width, speed = 14 + rng.next() * 16
                    let offset = rng.next() * 1000, r = 1 + rng.next() * 1.5, drift = (rng.next() - 0.5) * 24
                    let span = size.height + 20
                    let progress = animating ? (t * speed + offset).truncatingRemainder(dividingBy: span) : offset.truncatingRemainder(dividingBy: span)
                    let y = progress - 10
                    let x = x0 + drift * sin(progress / 40)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(HolidayColor.snow.opacity(0.45)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The gold star hanging over the top of the popover from Christmas Day.
struct HangingStar: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !animating)) { timeline in
            let t = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let cx = size.width / 2
                var string = Path(); string.move(to: CGPoint(x: cx, y: 0)); string.addLine(to: CGPoint(x: cx, y: 6))
                ctx.stroke(string, with: .color(HolidayColor.bronze), lineWidth: 0.8)
                var swing = ctx
                swing.translateBy(x: cx, y: 6); swing.rotate(by: .degrees(4 * sin(t * 2 * .pi / 3))); swing.translateBy(x: -cx, y: -6)
                let glow = 0.25 + 0.35 * (0.5 + 0.5 * sin(t * 2 * .pi / 2.4))
                swing.fill(Path(ellipseIn: CGRect(x: cx - 13, y: 4, width: 26, height: 26)), with: .color(HolidayColor.paleGold.opacity(glow)))
                let star = starPath(center: CGPoint(x: cx, y: 17), outer: 10, inner: 4.2)
                swing.fill(star, with: .color(HolidayColor.gold))
                swing.stroke(star, with: .color(HolidayColor.bronze), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
                swing.fill(starPath(center: CGPoint(x: cx, y: 17), outer: 4.2, inner: 1.8), with: .color(HolidayColor.paleGold))
            }
        }
        .frame(height: holidayStarHeight + 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// New Year's Day: small bursts in the band over the top of the popover, either side of the star.
struct Fireworks: View {
    let animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bursts: [(CGFloat, CGFloat, Color, Double)] = [
                    (0.18, 14, HolidayColor.gold, 0), (0.74, 12, HolidayColor.red, 0.7), (0.34, 16, HolidayColor.blue, 1.4),
                    (0.88, 15, HolidayColor.paleGold, 2.1), (0.62, 13, HolidayColor.rose, 2.8)]
                for (fx, cy, color, delay) in bursts {
                    let phase = ((t + 3.5 - delay).truncatingRemainder(dividingBy: 3.5)) / 3.5
                    let scale = CGFloat(min(1, phase / 0.9)), alpha = phase < 0.12 ? phase / 0.12 : max(0, 1 - (phase - 0.65) / 0.35)
                    guard alpha > 0 else { continue }
                    let cx = fx * size.width
                    for k in 0..<14 {
                        let a = Double(k) / 14 * 2 * .pi
                        var ray = Path()
                        ray.move(to: CGPoint(x: cx + cos(a) * 3 * scale, y: cy + sin(a) * 3 * scale))
                        ray.addLine(to: CGPoint(x: cx + cos(a) * 10 * scale, y: cy + sin(a) * 10 * scale))
                        ctx.stroke(ray, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        ctx.fill(Path(ellipseIn: CGRect(x: cx + cos(a) * 12 * scale - 1, y: cy + sin(a) * 12 * scale - 1, width: 2, height: 2)),
                                 with: .color(color.opacity(alpha)))
                    }
                }
            }
        }
        // Only in the band above the cards, where the star hangs: never behind any text.
        .frame(height: holidayStarHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The popover's decorations: wider by a branch on each side, snow behind the cards, the star
/// from Christmas Day and fireworks on New Year's Day. Off season it's the content as it was.
struct HolidayPopoverDecorations: ViewModifier {
    @ObservedObject var holiday: Holiday

    func body(content: Content) -> some View {
        let festive = holiday.isFestive
        let moving = holiday.popoverOpen && !holiday.stillMode
        let star = festive && (holiday.phase?.hasStar ?? false)
        content
            .padding(.horizontal, festive ? holidayBranchWidth : 0)
            .padding(.top, star ? holidayStarHeight : 0)
            .background(alignment: .top) {
                if festive {
                    ZStack(alignment: .top) {
                        SnowLayer(count: 22, animating: moving)
                        if holiday.phase == .newYearsDay { Fireworks(animating: moving) }
                        HStack(spacing: 0) {
                            BranchStrip(side: .leading, animating: moving)
                            Spacer(minLength: 0)
                            BranchStrip(side: .trailing, animating: moving)
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if star { HangingStar(animating: moving) }
            }
    }
}

extension View {
    /// The popover's holiday decorations. The plain view whenever they're off.
    public func holidayPopoverDecorations() -> some View {
        modifier(HolidayPopoverDecorations(holiday: .shared))
    }
}
