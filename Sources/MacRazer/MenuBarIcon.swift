// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Draws the app's mouse marks. (The silhouette-per-model mapping lives in
/// `RazerDevices` — the registry — so adding a mouse doesn't touch drawing code.)
enum MenuBarIcon {

    /// Razer yellow-green is the brand's; this is a battery-charging yellow, picked to read
    /// against a menu bar rather than to match the logo. Two of them, because one doesn't
    /// work in both places: system yellow disappears into a white menu bar, and the darker
    /// amber that fixes that looks muddy on black.
    static let chargingYellowOnDark = NSColor(red: 1.00, green: 0.84, blue: 0.13, alpha: 1)  // #FFD621
    static let chargingYellowOnLight = NSColor(red: 0.85, green: 0.58, blue: 0.00, alpha: 1) // #D99400

    /// A mouse silhouette with a small Razer triskelion cut into the body (even-odd).
    ///
    /// The idle mark is a **template** image: macOS recolors it for a light or dark menu bar,
    /// and inverts it while the item is highlighted, all for free.
    ///
    /// The charging mark cannot be, because a template image throws colour away — the same
    /// reason `AppDelegate` draws the update dot as a subview instead of baking it in. So the
    /// bolt's yellow costs us the automatic recolouring, and the body colour has to be chosen
    /// here from `appearance`. `AppDelegate` passes the status item's own effective appearance
    /// and rebuilds this icon when it changes, since nothing else will.
    static func mouse(pointSize: CGFloat = 16, razerCutout: Bool = true, charging: Bool = false,
                      appearance: NSAppearance? = nil) -> NSImage {
        guard charging else {
            let img = drawMouse(size: pointSize, razerCutout: razerCutout, silhouette: .cobra)
            img.isTemplate = true
            return img
        }
        // `currentDrawing()` is the sensible fallback: off the main actor there is no
        // NSApp to ask, and a caller drawing into a context has already set it.
        let isDark = (appearance ?? .currentDrawing())
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let img = drawMouse(size: pointSize, razerCutout: razerCutout, silhouette: .cobra,
                            color: isDark ? .white : .black, charging: true,
                            boltColor: isDark ? chargingYellowOnDark : chargingYellowOnLight)
        img.isTemplate = false
        return img
    }

    /// Same silhouette family, but shaped/detailed to match the specific connected model
    /// (by USB product ID) instead of always drawing the generic Cobra body. Falls back to
    /// the generic Cobra shape for an unknown or absent device.
    /// No charging variant here on purpose: this is the popover's header mark, and the card
    /// directly below it already spells out the charging state in words.
    static func mouseModel(pid: Int?, razerCutout: Bool = true, pointSize: CGFloat = 20) -> NSImage {
        let img = drawMouse(size: pointSize, razerCutout: razerCutout,
                            silhouette: RazerDevices.silhouette(pid: pid))
        img.isTemplate = true
        return img
    }

    /// `boltColor` defaults to `color` so every non-menu-bar caller (previews, the app icon)
    /// keeps drawing a single-colour mark.
    private static func drawMouse(size s: CGFloat, razerCutout: Bool, silhouette: RazerMouseSilhouette,
                                  color: NSColor = .black, charging: Bool = false,
                                  boltColor: NSColor? = nil) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let cx = rect.midX, cy = rect.midY
            let lw = s * 0.055
            // Body scale varies per model so the header icon reads as a different mouse:
            // Atheris is Razer's smallest/lowest-profile model here, Cobra Pro/HyperSpeed
            // the largest.
            let scale: CGFloat = silhouette == .atheris ? 0.84 : (silhouette == .cobraPro ? 1.05 : 1.0)
            // Normalised point: (x, y) in roughly [-0.5, 0.5], y up.
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + x * scale * s, y: cy + y * scale * s) }

            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)

            // Gaming-mouse body: narrow domed top, slight waist, wide rounded base.
            let body = CGMutablePath()
            body.move(to: P(0, 0.45))
            body.addCurve(to: P(0.24, 0.40), control1: P(0.12, 0.46), control2: P(0.19, 0.43))
            body.addCurve(to: P(0.29, 0.12), control1: P(0.30, 0.34), control2: P(0.30, 0.22))
            body.addCurve(to: P(0.34, -0.26), control1: P(0.28, 0.00), control2: P(0.33, -0.12))
            body.addCurve(to: P(0, -0.46), control1: P(0.35, -0.41), control2: P(0.20, -0.46))
            body.addCurve(to: P(-0.34, -0.26), control1: P(-0.20, -0.46), control2: P(-0.35, -0.41))
            body.addCurve(to: P(-0.29, 0.12), control1: P(-0.33, -0.12), control2: P(-0.28, 0.00))
            body.addCurve(to: P(-0.24, 0.40), control1: P(-0.30, 0.22), control2: P(-0.30, 0.34))
            body.addCurve(to: P(0, 0.45), control1: P(-0.19, 0.43), control2: P(-0.12, 0.46))
            body.closeSubpath()
            ctx.addPath(body)

            // Scroll-wheel pill at top-centre.
            let wheelW = s * 0.075
            let wheel = CGPath(roundedRect: CGRect(x: cx - wheelW / 2, y: cy + 0.16 * scale * s,
                                                   width: wheelW, height: 0.18 * s),
                               cornerWidth: wheelW / 2, cornerHeight: wheelW / 2, transform: nil)
            ctx.addPath(wheel)

            // Button-split line below the wheel — replaced by the charging bolt below, so the
            // body silhouette stays identical and only what's inside it changes.
            if !charging {
                ctx.move(to: P(0, 0.13))
                ctx.addLine(to: P(0, -0.10))
            }

            // Thumb buttons on the left edge: two on Cobra/Cobra Pro, one on the smaller Atheris.
            let bw = s * 0.115, bh = s * 0.072
            let thumbYs: [CGFloat] = silhouette == .atheris ? [0.12] : [0.175, 0.065]
            for yy in thumbYs {
                let r = CGRect(x: cx - 0.405 * scale * s, y: cy + yy * scale * s - bh / 2, width: bw, height: bh)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: bh * 0.45, cornerHeight: bh * 0.45, transform: nil))
            }

            // Cobra Pro/HyperSpeed add a visible on-the-fly DPI clutch button behind the wheel.
            // Suppressed while charging for the same reason as the triskelion below: the
            // enlarged bolt runs straight through this rect, and two marks overlapping read as
            // neither. Unreachable today (only `.cobra` ever charges), but the next per-model
            // charging icon should not have to rediscover it.
            if silhouette == .cobraPro && !charging {
                let dpi = CGRect(x: cx - wheelW * 0.55, y: cy - 0.02 * s, width: wheelW * 1.1, height: s * 0.05)
                ctx.addPath(CGPath(roundedRect: dpi, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
            }
            ctx.strokePath()

            // Charging bolt, filled rather than stroked: at menu bar size a stroked outline
            // closes up into a blob, while a solid glyph stays legible. Drawn after
            // `strokePath` so it isn't caught by the body's stroke.
            if charging {
                // Classic 6-point flash, in units of the bolt's own half-width/half-height
                // so the proportions hold at any icon size.
                //
                // Sized to fill the body rather than to replace the button-split line it
                // stands in for: this mark is read at ~21pt in a menu bar, out of the corner
                // of the eye, and a detail-sized glyph there is a smudge. It spans from just
                // under the scroll wheel (0.16) down to just inside the base stroke (-0.46
                // plus half the line width), keeping a hair of clearance at both ends so the
                // bolt never merges into the silhouette.
                let boltHalfW = 0.31, boltHalfH = 0.275, yOff: CGFloat = -0.128
                func B(_ x: CGFloat, _ y: CGFloat) -> CGPoint { P(x * boltHalfW, y * boltHalfH + yOff) }
                let bolt = CGMutablePath()
                bolt.move(to: B(0.35, 1.00))     // top tip
                bolt.addLine(to: B(-0.55, 0.05)) // down-left to the waist
                bolt.addLine(to: B(0.00, 0.05))  // jog back to centre
                bolt.addLine(to: B(-0.35, -1.00))// bottom tip
                bolt.addLine(to: B(0.55, -0.05)) // up-right to the waist
                bolt.addLine(to: B(0.00, -0.05)) // jog back to centre
                bolt.closeSubpath()
                ctx.addPath(bolt)
                ctx.setFillColor((boltColor ?? color).cgColor)
                ctx.fillPath()
            }

            // Triskelion mark near the base — but not while charging: the bolt now occupies
            // the body the triskelion sits in, and two marks on top of each other read as
            // neither. The menu bar passes `razerCutout: false` anyway; this keeps the
            // charging variant sane for every other caller.
            if razerCutout && !charging {
                let center = P(0, -0.29)
                let r = s * 0.105
                for k in 0..<3 {
                    let a = CGFloat(k) * (2 * .pi / 3) - .pi / 2
                    let perp = a + .pi / 2
                    func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
                        CGPoint(x: center.x + cos(a) * r * along + cos(perp) * s * side,
                                y: center.y + sin(a) * r * along + sin(perp) * s * side)
                    }
                    let blade = CGMutablePath()
                    blade.move(to: pt(0.0, -0.01))
                    blade.addCurve(to: pt(1.0, 0.035), control1: pt(0.35, 0.07), control2: pt(0.85, 0.07))
                    ctx.addPath(blade)
                }
                ctx.setLineWidth(lw * 0.85)
                ctx.strokePath()
            }
            return true
        }
    }

    /// An app-icon concept: the mouse mark (no Razer triskelion) on a rounded-square background.
    static func appIcon(size: CGFloat, bg: NSColor, mark: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.225
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            bg.setFill(); rect.fill()
            let m = size * 0.62
            drawMouse(size: m, razerCutout: false, silhouette: .cobra, color: mark)
                .draw(in: NSRect(x: (size - m) / 2, y: (size - m) / 2, width: m, height: m))
            return true
        }
    }

    static func writeAppIcon(to path: String, size: CGFloat, bg: NSColor, mark: NSColor) {
        let image = appIcon(size: size, bg: bg, mark: mark)
        let px = Int(size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Render a mark to a PNG file (used by the `icon` CLI command for visual verification).
    @discardableResult
    static func writePreview(to path: String, size: CGFloat, silhouette: RazerMouseSilhouette = .cobra,
                             razerCutout: Bool = true, charging: Bool = false,
                             lightMenuBar: Bool = false) -> Bool {
        // Charging previews reproduce a real menu-bar pairing — body and bolt colour both
        // depend on it, and the light one is the harder of the two to get right (yellow on
        // white). Non-charging keeps the brand green: it's a shape check, not a colour one.
        let image = drawMouse(size: size, razerCutout: razerCutout, silhouette: silhouette,
                              color: charging ? (lightMenuBar ? .black : .white)
                                  : NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1),
                              charging: charging,
                              boltColor: charging
                                  ? (lightMenuBar ? chargingYellowOnLight : chargingYellowOnDark)
                                  : nil)
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Backdrop matches the menu bar being previewed — a light-mode mark on a dark square
        // would tell you nothing about the contrast that actually matters.
        (lightMenuBar ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("[MacRazer] icon write failed: \(error)\n".utf8))
            return false
        }
    }
}
