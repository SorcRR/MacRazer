// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// How long a present takes to open: three shakes, the lid off, the gift up.
private let openingSeconds: Double = 1.2
private let sceneHeight: CGFloat = 112
private let nightTop = Color(hex: 0x16213A)
private let nightBottom = Color(hex: 0x24365A)
private let stripFill = Color(hex: 0x121A2C)

/// The wrapping on each of the three boxes: its size, paper and ribbon.
private struct Wrapping {
    enum Pattern { case stripes, stars, dots }
    let width: CGFloat
    let height: CGFloat
    let paper: Color
    let print: Color
    let ribbon: Color
    let pattern: Pattern
    let spoken: String

    static let all: [Wrapping] = [
        Wrapping(width: 58, height: 50, paper: HolidayColor.red, print: Color.white.opacity(0.55),
                 ribbon: HolidayColor.paleGold, pattern: .stripes, spoken: "red striped paper"),
        Wrapping(width: 48, height: 62, paper: HolidayColor.blue, print: HolidayColor.paleGold,
                 ribbon: HolidayColor.red, pattern: .stars, spoken: "blue paper with stars"),
        Wrapping(width: 54, height: 42, paper: HolidayColor.darkGreen, print: Color.white.opacity(0.7),
                 ribbon: HolidayColor.red, pattern: .dots, spoken: "green paper with dots"),
    ]
}

/// "Under the tree": three presents on December 25 and 26, wrapped and greyed on the 24th.
/// Opening one happens in place. The card can be hidden; Settings brings it back. The plain
/// nothing on every other day, and whenever the decorations are off.
public struct HolidayPresentsCard: View {
    @ObservedObject private var holiday = Holiday.shared
    @ObservedObject private var presents = HolidayPresents.shared
    /// When each box started opening in this view, for the animation.
    @State private var openedAt: [Int: Date] = [:]
    @State private var undoShown = false
    /// Each hide gets its own five seconds: an older timer never cuts a newer notice short.
    @State private var undoToken = UUID()

    public init() {}

    public var body: some View {
        if let stage = holiday.presentsStage {
            if presents.hidden {
                if undoShown { hiddenNotice }
            } else {
                card(stage)
            }
        }
    }

    private func card(_ stage: HolidayPresentsStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(stage)
            VStack(spacing: 0) {
                scene(stage)
                if let box = presents.featured, let gift = presents.gift(in: box) {
                    GiftStrip(gift: gift)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
    }

    private func header(_ stage: HolidayPresentsStage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gift.fill").font(.system(size: 13)).foregroundStyle(HolidayColor.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(presents.allOpened ? "Your presents" : "Under the tree")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle(stage)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: hide) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the presents")
            .accessibilityLabel("Hide the presents")
        }
    }

    private func subtitle(_ stage: HolidayPresentsStage) -> String {
        if stage == .waiting { return "Do not open until Christmas" }
        let left = HolidayPresents.count - presents.opened.count
        switch left {
        case 0: return "All opened. Merry Christmas."
        case HolidayPresents.count: return "Three presents for you. Click one to open it."
        default: return left == 1 ? "One more to open" : "\(left) more to open"
        }
    }

    private func scene(_ stage: HolidayPresentsStage) -> some View {
        ZStack(alignment: .bottom) {
            NightScene()
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<HolidayPresents.count, id: \.self) { box in
                    slot(box, stage: stage).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 10)
        }
        .frame(height: sceneHeight)
    }

    @ViewBuilder
    private func slot(_ box: Int, stage: HolidayPresentsStage) -> some View {
        let wrapping = Wrapping.all[box]
        if let gift = presents.gift(in: box) {
            OpenedPresent(gift: gift, wrapping: wrapping, startedAt: openedAt[box],
                          still: holiday.stillMode, featured: presents.featured == box) {
                presents.featured = box
            }
        } else {
            WrappedPresent(wrapping: wrapping, waiting: stage == .waiting, still: holiday.stillMode,
                           number: box + 1) { open(box) }
        }
    }

    private func open(_ box: Int) {
        guard let gift = presents.open(box) else { return }
        if !holiday.stillMode { openedAt[box] = Date() }
        let rarity: String
        switch gift.rarity {
        case .regular: rarity = ""
        case .rare: rarity = " Rare."
        case .veryRare: rarity = " Very rare."
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(gift.name).\(rarity) \(gift.line)",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func hide() {
        presents.setHidden(true)
        undoShown = true
        let token = UUID()
        undoToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if undoToken == token { undoShown = false }
        }
    }

    private var hiddenNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "gift").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Presents hidden. Bring them back in Settings.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Undo") {
                undoShown = false
                presents.setHidden(false)
            }
            .buttonStyle(HolidayPillButton(filled: false))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
    }
}

/// The night behind the presents: a garland with lights along the top, a few stars, and snow
/// on the ground. Drawn once.
private struct NightScene: View {
    var body: some View {
        Canvas { ctx, size in
            let sky = Gradient(colors: [nightTop, nightBottom])
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            drawStars(ctx, size)
            drawGarland(ctx, size)
            drawSnow(ctx, size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawStars(_ ctx: GraphicsContext, _ size: CGSize) {
        var rng = SeededRandom(seed: 41)
        for _ in 0..<18 {
            let x = rng.next() * size.width, y = 18 + rng.next() * (size.height * 0.45)
            let r = 0.5 + rng.next() * 0.8
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Color.white.opacity(0.35 + rng.next() * 0.4)))
        }
    }

    private func garlandY(_ x: CGFloat, _ width: CGFloat) -> CGFloat {
        let swag = width / 3
        let local = x.truncatingRemainder(dividingBy: swag) / swag
        return 4 + 8 * sin(local * .pi)
    }

    private func drawGarland(_ ctx: GraphicsContext, _ size: CGSize) {
        var rng = SeededRandom(seed: 52)
        for x in stride(from: CGFloat(0), through: size.width, by: 2) {
            let y = garlandY(x, size.width)
            for _ in 0..<2 {
                let angle = rng.next() * 2 * .pi, length = 4 + rng.next() * 4
                var needle = Path()
                needle.move(to: CGPoint(x: x, y: y))
                needle.addLine(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length))
                let color = HolidayColor.needles[Int(rng.next() * 4.99)]
                ctx.stroke(needle, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        var i = 0
        for x in stride(from: CGFloat(10), to: size.width, by: 22) {
            let y = garlandY(x, size.width) + 4
            let color = HolidayColor.lights[i % HolidayColor.lights.count]
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 3, width: 10, height: 10)), with: .color(color.opacity(0.3)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y, width: 4.4, height: 5.6)), with: .color(color))
            i += 1
        }
    }

    private func drawSnow(_ ctx: GraphicsContext, _ size: CGSize) {
        var ground = Path()
        ground.move(to: CGPoint(x: 0, y: size.height - 16))
        ground.addQuadCurve(to: CGPoint(x: size.width * 0.5, y: size.height - 18),
                            control: CGPoint(x: size.width * 0.25, y: size.height - 24))
        ground.addQuadCurve(to: CGPoint(x: size.width, y: size.height - 15),
                            control: CGPoint(x: size.width * 0.75, y: size.height - 12))
        ground.addLine(to: CGPoint(x: size.width, y: size.height))
        ground.addLine(to: CGPoint(x: 0, y: size.height))
        ground.closeSubpath()
        ctx.fill(ground, with: .color(Color(hex: 0xE6EEF8)))
    }
}

/// A wrapped box: body, lid with its bow, and a gift tag. Lifts a little under the pointer.
private struct WrappedPresent: View {
    let wrapping: Wrapping
    let waiting: Bool
    let still: Bool
    let number: Int
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            BoxArt(wrapping: wrapping, lidLift: 0, lidTurn: 0, glow: 0, seam: Color.white)
                .frame(width: wrapping.width + 8, height: wrapping.height + 16)
                .offset(y: hovered && !waiting ? -3 : 0)
                .animation(still ? nil : .easeOut(duration: 0.15), value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(waiting)
        .saturation(waiting ? 0.25 : 1)
        .opacity(waiting ? 0.6 : 1)
        .onHover { hovered = $0 }
        .help(waiting ? "Do not open until Christmas" : "Open this present")
        .accessibilityLabel("Present \(number) of 3, \(wrapping.spoken)")
        .accessibilityHint(waiting ? "Opens on Christmas Day" : "Opens it")
    }
}

/// A box drawn in parts, so opening can lift the lid off and let light out of the seam.
private struct BoxArt: View {
    let wrapping: Wrapping
    /// How far the lid has flown up, in points.
    let lidLift: CGFloat
    let lidTurn: Double
    /// Light leaking out of the seam, 0 to 1.
    let glow: Double
    let seam: Color

    var body: some View {
        Canvas { ctx, size in
            let lidHeight = wrapping.height * 0.24
            let bodyRect = CGRect(x: (size.width - wrapping.width) / 2, y: size.height - wrapping.height + lidHeight,
                                  width: wrapping.width, height: wrapping.height - lidHeight)
            // The light spills out from behind the lid, so the halo goes under the box.
            if glow > 0 { drawHalo(ctx, bodyRect) }
            drawBody(ctx, bodyRect)
            if glow > 0 { drawSeam(ctx, bodyRect) }
            var lid = ctx
            lid.translateBy(x: bodyRect.midX, y: bodyRect.minY - lidLift)
            lid.rotate(by: .degrees(lidTurn))
            drawLid(lid, width: wrapping.width + 4, height: lidHeight)
        }
        .allowsHitTesting(false)
    }

    private func drawBody(_ ctx: GraphicsContext, _ rect: CGRect) {
        let box = Path(roundedRect: rect, cornerRadius: 2)
        ctx.fill(box, with: .color(wrapping.paper))
        var paper = ctx
        paper.clip(to: box)
        drawPattern(paper, rect)
        // Shade on the right, so it reads as a box rather than a tile.
        paper.fill(Path(CGRect(x: rect.maxX - rect.width * 0.28, y: rect.minY, width: rect.width * 0.28, height: rect.height)),
                   with: .color(Color.black.opacity(0.16)))
        let ribbon = CGRect(x: rect.midX - 4, y: rect.minY, width: 8, height: rect.height)
        paper.fill(Path(ribbon), with: .color(wrapping.ribbon))
        paper.fill(Path(CGRect(x: ribbon.maxX - 2.5, y: rect.minY, width: 2.5, height: rect.height)),
                   with: .color(Color.black.opacity(0.15)))
        drawTag(ctx, rect)
    }

    private func drawPattern(_ ctx: GraphicsContext, _ rect: CGRect) {
        switch wrapping.pattern {
        case .stripes:
            var x = rect.minX - rect.height
            while x < rect.maxX {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: rect.maxY))
                stripe.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                stripe.addLine(to: CGPoint(x: x + rect.height + 4, y: rect.minY))
                stripe.addLine(to: CGPoint(x: x + 4, y: rect.maxY))
                stripe.closeSubpath()
                ctx.fill(stripe, with: .color(wrapping.print))
                x += 10
            }
        case .stars:
            for row in 0..<4 {
                for col in 0..<4 {
                    let cx = rect.minX + 6 + CGFloat(col) * 12 + (row % 2 == 0 ? 0 : 6)
                    let cy = rect.minY + 7 + CGFloat(row) * 12
                    ctx.fill(starPath(center: CGPoint(x: cx, y: cy), outer: 2.8, inner: 1.2), with: .color(wrapping.print))
                }
            }
        case .dots:
            for row in 0..<4 {
                for col in 0..<6 {
                    let cx = rect.minX + 5 + CGFloat(col) * 10 + (row % 2 == 0 ? 0 : 5)
                    let cy = rect.minY + 6 + CGFloat(row) * 9
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - 1.6, y: cy - 1.6, width: 3.2, height: 3.2)), with: .color(wrapping.print))
                }
            }
        }
    }

    private func drawTag(_ ctx: GraphicsContext, _ rect: CGRect) {
        var string = Path()
        string.move(to: CGPoint(x: rect.midX + 4, y: rect.minY + 3))
        string.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.minY + 10))
        ctx.stroke(string, with: .color(Color(hex: 0xD3D1C7)), lineWidth: 0.6)
        let tag = Path(roundedRect: CGRect(x: rect.maxX - 11, y: rect.minY + 9, width: 9, height: 6), cornerRadius: 1)
        ctx.fill(tag, with: .color(Color(hex: 0xF4EAD5)))
    }

    private func drawHalo(_ ctx: GraphicsContext, _ rect: CGRect) {
        let centre = CGPoint(x: rect.midX, y: rect.minY)
        let radius = rect.width * 0.75
        let light = Gradient(colors: [seam.opacity(0.8 * glow), seam.opacity(0)])
        let area = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: area),
                 with: .radialGradient(light, center: centre, startRadius: 0, endRadius: radius))
    }

    private func drawSeam(_ ctx: GraphicsContext, _ rect: CGRect) {
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 2)), with: .color(seam.opacity(glow)))
    }

    private func drawLid(_ ctx: GraphicsContext, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: -width / 2, y: -height, width: width, height: height)
        let lid = Path(roundedRect: rect, cornerRadius: 2)
        ctx.fill(lid, with: .color(wrapping.paper))
        var paper = ctx
        paper.clip(to: lid)
        drawPattern(paper, rect)
        paper.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)), with: .color(Color.black.opacity(0.18)))
        paper.fill(Path(CGRect(x: -4, y: rect.minY, width: 8, height: rect.height)), with: .color(wrapping.ribbon))
        drawBow(ctx, top: rect.minY)
    }

    private func drawBow(_ ctx: GraphicsContext, top: CGFloat) {
        let color = wrapping.ribbon
        for side in [-1.0, 1.0] as [CGFloat] {
            var loop = ctx
            loop.translateBy(x: side * 5.5, y: top - 3.5)
            loop.rotate(by: .degrees(Double(side) * -18))
            let shape = Path(ellipseIn: CGRect(x: -5.5, y: -3.8, width: 11, height: 7.6))
            loop.fill(shape, with: .color(color))
            loop.fill(Path(ellipseIn: CGRect(x: -2.5, y: -1.6, width: 5, height: 3.2)), with: .color(Color.black.opacity(0.18)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: -2.8, y: top - 6, width: 5.6, height: 5.6)), with: .color(color))
    }
}

/// An opened present: while it opens, the box shakes, light leaks out, the lid flies and the
/// gift rises; then the gift stays where the box was, its name on a dark pill.
private struct OpenedPresent: View {
    let gift: HolidayGift
    let wrapping: Wrapping
    let startedAt: Date?
    let still: Bool
    let featured: Bool
    let onSelect: () -> Void

    var body: some View {
        #if DEBUG
        // `MACRAZER_HOLIDAY_OPENING=0.6` draws every open box that far into its opening, for renders.
        if let text = ProcessInfo.processInfo.environment["MACRAZER_HOLIDAY_OPENING"], let t = Double(text) {
            OpeningFrame(gift: gift, wrapping: wrapping, t: t)
        } else {
            animated
        }
        #else
        animated
        #endif
    }

    @ViewBuilder
    private var animated: some View {
        if let startedAt, !still {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let t = timeline.date.timeIntervalSince(startedAt)
                if t < openingSeconds + 0.3 {
                    OpeningFrame(gift: gift, wrapping: wrapping, t: t)
                } else {
                    result
                }
            }
        } else {
            result
        }
    }

    private var result: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                GiftIcon(gift: gift, size: 30, rays: gift.rarity != .regular ? 1 : 0)
                NamePill(gift: gift)
            }
        }
        .buttonStyle(.plain)
        .opacity(featured ? 1 : 0.92)
        .accessibilityLabel(gift.name)
        .accessibilityHint(gift.line)
    }
}

/// One moment of the opening, `t` seconds in.
private struct OpeningFrame: View {
    let gift: HolidayGift
    let wrapping: Wrapping
    let t: Double
    private let lidRoom: CGFloat = 56

    var body: some View {
        let shakeEnd = 0.72, lidEnd = 0.95
        let shaking = t < shakeEnd
        let strength = min(1, t / shakeEnd)
        let angle = shaking ? sin(t * 3 / shakeEnd * 2 * .pi) * (3 + 7 * strength) : 0
        let lidProgress = CGFloat(max(0, min(1, (t - shakeEnd) / (lidEnd - shakeEnd))))
        let rise = max(0, min(1, (t - 0.8) / (openingSeconds - 0.8)))
        let glow = shaking ? 0.3 + 0.7 * strength : max(0, 1 - Double(lidProgress))
        let boxFade = t < lidEnd ? 1 : max(0, 1 - (t - lidEnd) / 0.2)
        ZStack(alignment: .bottom) {
            // Room above the box for the lid to fly into.
            BoxArt(wrapping: wrapping, lidLift: lidProgress * 44, lidTurn: Double(lidProgress) * 28,
                   glow: glow, seam: seamColor)
                .frame(width: wrapping.width + 60, height: wrapping.height + 16 + lidRoom)
                .rotationEffect(.degrees(angle), anchor: .bottom)
                .opacity(boxFade)
            if rise > 0 {
                VStack(spacing: 4) {
                    GiftIcon(gift: gift, size: 30, rays: rise)
                    NamePill(gift: gift).opacity(rise)
                }
                .scaleEffect(0.4 + 0.6 * rise, anchor: .bottom)
                .offset(y: CGFloat(1 - rise) * 12)
                Confetti(progress: rise)
                    .frame(width: 90, height: 80)
                    .offset(y: -10)
            }
        }
    }

    /// White for a regular gift, cream for the golden mouse, gold for the chocolate.
    private var seamColor: Color {
        switch gift.rarity {
        case .regular: Color.white
        case .rare: Color(hex: 0xFFF1D0)
        case .veryRare: HolidayColor.paleGold
        }
    }
}

/// The gift itself, with rays behind it while it rises, and for good on a rare one.
private struct GiftIcon: View {
    let gift: HolidayGift
    let size: CGFloat
    /// 0 to 1: how strong the rays are.
    let rays: Double

    var body: some View {
        ZStack {
            if rays > 0 {
                Canvas { ctx, canvas in
                    let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                    let color = gift.rarity == .regular ? Color.white : HolidayColor.gold
                    for k in 0..<10 {
                        let a = Double(k) / 10 * 2 * .pi
                        var ray = Path()
                        ray.move(to: CGPoint(x: centre.x + cos(a) * size * 0.45, y: centre.y + sin(a) * size * 0.45))
                        ray.addLine(to: CGPoint(x: centre.x + cos(a) * size * 0.75, y: centre.y + sin(a) * size * 0.75))
                        ctx.stroke(ray, with: .color(color.opacity(0.9 * rays)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    }
                }
                .frame(width: size * 1.6, height: size * 1.6)
            }
            if gift.rarity != .regular {
                Circle()
                    .fill(RadialGradient(colors: [HolidayColor.paleGold.opacity(0.85), HolidayColor.gold.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 0.6))
                    .frame(width: size * 1.2, height: size * 1.2)
            }
            Text(gift.emoji).font(.system(size: size * 0.8))
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .accessibilityHidden(true)
    }
}

/// A gift's name on a dark pill (a gold one for the rare gifts): never white on the snow.
private struct NamePill: View {
    let gift: HolidayGift

    var body: some View {
        Text(gift.name)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(gift.rarity == .regular ? Color.white : HolidayColor.ink)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(gift.rarity == .regular ? AnyShapeStyle(stripFill.opacity(0.88)) : AnyShapeStyle(HolidayColor.paleGold),
                        in: Capsule())
            .accessibilityHidden(true)
    }
}

/// Confetti bursting up and drifting down as the gift rises.
private struct Confetti: View {
    let progress: Double

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 77)
            let colors = HolidayColor.lights
            for k in 0..<16 {
                let angle = -Double.pi / 2 + (rng.next() - 0.5) * 2.4
                let speed = 30 + rng.next() * 22
                let p = progress
                let x = size.width / 2 + CGFloat(cos(angle) * speed * p)
                let y = size.height * 0.7 + CGFloat(sin(angle) * speed * p + 40 * p * p)
                var piece = ctx
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .degrees(rng.next() * 360 + p * 200))
                piece.fill(Path(CGRect(x: -1.6, y: -1, width: 3.2, height: 2)),
                           with: .color(colors[k % colors.count].opacity(max(0, 1 - p * 0.6))))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The strip under the scene: the gift picked out, what it is, and how rare.
private struct GiftStrip: View {
    let gift: HolidayGift

    var body: some View {
        HStack(spacing: 9) {
            Text(gift.emoji).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 1) {
                Text(gift.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                Text(gift.line).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HolidayColor.ink)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(HolidayColor.paleGold, in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stripFill)
        .accessibilityElement(children: .combine)
    }

    private var badge: String? {
        switch gift.rarity {
        case .regular: nil
        case .rare: "Rare"
        case .veryRare: "Very rare"
        }
    }
}
