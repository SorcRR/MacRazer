// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The season's colours, from the design mockups. Fixed values: the decorations look the same
/// on every theme, and each was checked against light and dark.
enum HolidayColor {
    static let red = Color(hex: 0xE24B4A)
    static let deepRed = Color(hex: 0xA32D2D)
    static let wine = Color(hex: 0x791F1F)
    static let blush = Color(hex: 0xFCEBEB)
    static let pink = Color(hex: 0xF09595)
    static let green = Color(hex: 0x639922)
    static let darkGreen = Color(hex: 0x3B6D11)
    static let gold = Color(hex: 0xEF9F27)
    static let paleGold = Color(hex: 0xFAC775)
    static let bronze = Color(hex: 0xBA7517)
    static let brown = Color(hex: 0x854F0B)
    static let bark = Color(hex: 0x633806)
    static let ink = Color(hex: 0x2C2C2A)
    static let skin = Color(hex: 0xF5C4B3)
    static let snow = Color(hex: 0xB5D4F4)
    static let blue = Color(hex: 0x378ADD)
    static let rose = Color(hex: 0xD4537E)
    static let needles: [Color] = [0x173404, 0x27500A, 0x3B6D11, 0x639922, 0x97C459].map { Color(hex: $0) }
    static let lights: [Color] = [red, gold, blue, rose, paleGold]
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// A small repeatable random source, so the branches and snow look the same every time the
/// popover opens instead of reshuffling.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
    }
}

/// Points of a five-pointed star, for paths.
func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> Path {
    Path { p in
        for i in 0..<10 {
            let angle = -Double.pi / 2 + Double(i) * .pi / 5
            let r = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
    }
}

private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

private func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
}

/// The green tree that stands in for the mouse icon, with its star from Christmas Day.
public struct HolidayTreeIcon: View {
    let star: Bool
    public init(star: Bool) { self.star = star }

    public var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 24, y: size.height / 24)
            if star {
                ctx.fill(starPath(center: CGPoint(x: 12, y: 3.2), outer: 3.2, inner: 1.4), with: .color(HolidayColor.gold))
            }
            let tree = Path { p in
                p.move(to: CGPoint(x: 12, y: 5))
                for (x, y) in [(17, 11), (14.5, 11), (18.5, 16), (15.5, 16), (19.5, 20.5), (4.5, 20.5),
                               (8.5, 16), (5.5, 16), (9.5, 11), (7, 11)] as [(CGFloat, CGFloat)] {
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.closeSubpath()
            }
            ctx.fill(tree, with: .color(HolidayColor.green))
            ctx.stroke(tree, with: .color(HolidayColor.darkGreen), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            ctx.fill(Path(CGRect(x: 10.8, y: 20.5, width: 2.4, height: 2.5)), with: .color(HolidayColor.brown))
            ctx.fill(circle(10, 13, 0.9), with: .color(HolidayColor.red))
            ctx.fill(circle(14, 15.5, 0.9), with: .color(HolidayColor.paleGold))
            ctx.fill(circle(9, 18.5, 0.9), with: .color(HolidayColor.blue))
            ctx.fill(circle(15, 19, 0.9), with: .color(HolidayColor.red))
        }
        .accessibilityHidden(true)
    }
}

/// The characters, drawn from the mockups' artwork. `glow` drives Rudolph's nose and the
/// elf's bell, 0 to 1.
struct HolidayCharacterArt: View {
    let character: HolidayCharacter
    var glow: Double = 0.5

    var body: some View {
        Canvas { ctx, size in
            switch character {
            case .santa:
                ctx.scaleBy(x: size.width / 30, y: size.height / 30)
                drawSanta(ctx)
            case .reindeer:
                ctx.scaleBy(x: size.width / 30, y: size.height / 30)
                drawReindeer(ctx)
            case .elf:
                ctx.scaleBy(x: size.width / 32, y: size.height / 32)
                drawElf(ctx)
            case .krampus:
                ctx.scaleBy(x: size.width / 64, y: size.height / 64)
                drawKrampus(ctx)
            }
        }
    }

    private func drawSanta(_ ctx: GraphicsContext) {
        let white = Color.white, line = Color(hex: 0xD3D1C7)
        let hat = Path { p in
            p.move(to: CGPoint(x: 6, y: 13)); p.addQuadCurve(to: CGPoint(x: 24, y: 6), control: CGPoint(x: 14, y: 1))
            p.addLine(to: CGPoint(x: 27, y: 12)); p.closeSubpath()
        }
        ctx.fill(hat, with: .color(HolidayColor.red))
        ctx.fill(circle(27, 12, 2.6), with: .color(white))
        ctx.fill(circle(15, 17, 7.5), with: .color(HolidayColor.skin))
        let brim = Path(roundedRect: CGRect(x: 5.5, y: 11.5, width: 19, height: 4), cornerRadius: 2)
        ctx.fill(brim, with: .color(white)); ctx.stroke(brim, with: .color(line), lineWidth: 0.5)
        let beard = Path { p in
            p.move(to: CGPoint(x: 7, y: 18))
            p.addQuadCurve(to: CGPoint(x: 15, y: 30), control: CGPoint(x: 8, y: 30))
            p.addQuadCurve(to: CGPoint(x: 23, y: 18), control: CGPoint(x: 22, y: 30))
            p.addQuadCurve(to: CGPoint(x: 15, y: 21), control: CGPoint(x: 19, y: 22))
            p.addQuadCurve(to: CGPoint(x: 7, y: 18), control: CGPoint(x: 11, y: 22))
            p.closeSubpath()
        }
        ctx.fill(beard, with: .color(white)); ctx.stroke(beard, with: .color(line), lineWidth: 0.5)
        ctx.fill(circle(12.2, 17.4, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(17.8, 17.4, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(15, 20, 1.4), with: .color(HolidayColor.red))
    }

    private func drawReindeer(_ ctx: GraphicsContext) {
        let antlers = Path { p in
            for (a, b) in [((10, 11), (7, 4)), ((8.3, 7), (4.5, 6)), ((7.5, 5), (8, 2)),
                           ((20, 11), (23, 4)), ((21.7, 7), (25.5, 6)), ((22.5, 5), (22, 2))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
                p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1))
            }
        }
        ctx.stroke(antlers, with: .color(HolidayColor.bark), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        ctx.fill(ellipse(7.5, 13, 3, 1.6), with: .color(HolidayColor.brown))
        ctx.fill(ellipse(22.5, 13, 3, 1.6), with: .color(HolidayColor.brown))
        let head = Path { p in
            p.move(to: CGPoint(x: 9, y: 13)); p.addQuadCurve(to: CGPoint(x: 21, y: 13), control: CGPoint(x: 15, y: 8))
            p.addLine(to: CGPoint(x: 20, y: 22)); p.addQuadCurve(to: CGPoint(x: 10, y: 22), control: CGPoint(x: 15, y: 29))
            p.closeSubpath()
        }
        ctx.fill(head, with: .color(HolidayColor.bronze))
        ctx.fill(ellipse(15, 23, 4.2, 3.4), with: .color(HolidayColor.paleGold))
        ctx.fill(circle(12.3, 16, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(17.7, 16, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(15, 23.5, 4.2), with: .color(HolidayColor.red.opacity(0.3 + 0.5 * glow)))
        ctx.fill(circle(15, 23.5, 2.3), with: .color(HolidayColor.red))
        ctx.fill(circle(14.2, 22.8, 0.7), with: .color(.white.opacity(0.8)))
    }

    private func drawElf(_ ctx: GraphicsContext) {
        let hat = Path { p in
            p.move(to: CGPoint(x: 7, y: 13)); p.addQuadCurve(to: CGPoint(x: 26, y: 4), control: CGPoint(x: 14, y: -2))
            p.addLine(to: CGPoint(x: 24, y: 7)); p.addQuadCurve(to: CGPoint(x: 25, y: 13), control: CGPoint(x: 16, y: 4))
            p.closeSubpath()
        }
        ctx.fill(hat, with: .color(HolidayColor.darkGreen))
        var bell = ctx
        bell.translateBy(x: 26.5, y: 5); bell.rotate(by: .degrees(-10 + 20 * glow)); bell.translateBy(x: -26.5, y: -5)
        bell.fill(circle(26.5, 6, 2.2), with: .color(HolidayColor.paleGold))
        let ears = Path { p in
            p.move(to: CGPoint(x: 5, y: 17)); p.addLine(to: CGPoint(x: 1, y: 12)); p.addLine(to: CGPoint(x: 8, y: 15)); p.closeSubpath()
            p.move(to: CGPoint(x: 27, y: 17)); p.addLine(to: CGPoint(x: 31, y: 12)); p.addLine(to: CGPoint(x: 24, y: 15)); p.closeSubpath()
        }
        ctx.fill(ears, with: .color(HolidayColor.skin))
        ctx.fill(circle(16, 19, 8), with: .color(HolidayColor.skin))
        ctx.fill(Path(roundedRect: CGRect(x: 6, y: 12, width: 20, height: 3.6), cornerRadius: 1.8), with: .color(HolidayColor.red))
        ctx.fill(circle(12.8, 18.5, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(19.2, 18.5, 1), with: .color(HolidayColor.ink))
        ctx.fill(circle(11, 21.5, 1.6), with: .color(HolidayColor.pink.opacity(0.7)))
        ctx.fill(circle(21, 21.5, 1.6), with: .color(HolidayColor.pink.opacity(0.7)))
        let smile = Path { p in
            p.move(to: CGPoint(x: 13, y: 23)); p.addQuadCurve(to: CGPoint(x: 19, y: 23), control: CGPoint(x: 16, y: 25.5))
        }
        ctx.stroke(smile, with: .color(Color(hex: 0x993C1D)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
    }

    private func drawKrampus(_ ctx: GraphicsContext) {
        let horn = Color(hex: 0xF1EFE8), hornLine = Color(hex: 0x888780), dark = Color(hex: 0x412402)
        let horns = Path { p in
            p.move(to: CGPoint(x: 18, y: 22))
            p.addCurve(to: CGPoint(x: 14, y: 4), control1: CGPoint(x: 10, y: 18), control2: CGPoint(x: 8, y: 8))
            p.addCurve(to: CGPoint(x: 24, y: 18), control1: CGPoint(x: 14, y: 12), control2: CGPoint(x: 18, y: 16))
            p.closeSubpath()
            p.move(to: CGPoint(x: 46, y: 22))
            p.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 54, y: 18), control2: CGPoint(x: 56, y: 8))
            p.addCurve(to: CGPoint(x: 40, y: 18), control1: CGPoint(x: 50, y: 12), control2: CGPoint(x: 46, y: 16))
            p.closeSubpath()
        }
        ctx.fill(horns, with: .color(horn)); ctx.stroke(horns, with: .color(hornLine), lineWidth: 0.8)
        let furPoints: [(CGFloat, CGFloat)] = [(14, 30), (10, 27), (15, 26), (12, 22), (18, 23), (17, 18), (23, 21), (26, 15),
            (30, 20), (34, 14), (37, 20), (42, 15), (44, 21), (49, 18), (48, 23), (54, 22), (51, 26), (56, 27), (52, 31),
            (56, 36), (51, 37), (54, 42), (48, 42), (49, 48), (43, 46), (41, 52), (36, 48), (32, 54), (28, 48), (23, 52),
            (21, 46), (15, 48), (16, 42), (10, 42), (13, 37), (8, 36)]
        let fur = Path { p in
            p.move(to: CGPoint(x: furPoints[0].0, y: furPoints[0].1))
            for pt in furPoints.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
            p.closeSubpath()
        }
        ctx.fill(fur, with: .color(HolidayColor.brown))
        ctx.fill(ellipse(32, 35, 15, 13), with: .color(HolidayColor.bronze))
        let brows = Path { p in
            p.move(to: CGPoint(x: 21, y: 29)); p.addLine(to: CGPoint(x: 28, y: 31))
            p.move(to: CGPoint(x: 43, y: 29)); p.addLine(to: CGPoint(x: 36, y: 31))
        }
        ctx.stroke(brows, with: .color(dark), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        ctx.fill(circle(26, 34, 3.2), with: .color(HolidayColor.paleGold))
        ctx.fill(circle(38, 34, 3.2), with: .color(HolidayColor.paleGold))
        ctx.fill(circle(26.5, 34.5, 1.4), with: .color(dark))
        ctx.fill(circle(37.5, 34.5, 1.4), with: .color(dark))
        let mouth = Path { p in
            p.move(to: CGPoint(x: 24, y: 41)); p.addQuadCurve(to: CGPoint(x: 40, y: 41), control: CGPoint(x: 32, y: 46))
            p.addQuadCurve(to: CGPoint(x: 24, y: 41), control: CGPoint(x: 32, y: 44)); p.closeSubpath()
        }
        ctx.fill(mouth, with: .color(dark))
        let tongueLength = 50 + 5 * glow
        let tongue = Path { p in
            p.move(to: CGPoint(x: 29, y: 43)); p.addQuadCurve(to: CGPoint(x: 35, y: 43), control: CGPoint(x: 32, y: tongueLength))
            p.closeSubpath()
        }
        ctx.fill(tongue, with: .color(HolidayColor.red))
        let teeth = Path { p in
            p.move(to: CGPoint(x: 27, y: 41.5)); p.addLine(to: CGPoint(x: 28, y: 44)); p.addLine(to: CGPoint(x: 29, y: 41.8)); p.closeSubpath()
            p.move(to: CGPoint(x: 35, y: 41.8)); p.addLine(to: CGPoint(x: 36, y: 44)); p.addLine(to: CGPoint(x: 37, y: 41.5)); p.closeSubpath()
        }
        ctx.fill(teeth, with: .color(.white))
        ctx.fill(circle(32, 57, 3), with: .color(HolidayColor.paleGold))
        ctx.stroke(circle(32, 57, 3), with: .color(HolidayColor.bronze), lineWidth: 0.8)
    }
}
