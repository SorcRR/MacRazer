// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import AppKit

/// Which body shape `MenuBarIcon.mouseModel` should draw, grouped by physical chassis rather
/// than by SKU — wired/wireless variants of the same mouse share a shape.
enum RazerMouseSilhouette {
    case cobra
    case cobraPro
    case atheris

    /// Maps a connected device's USB product ID (see `RazerDevices.known`) to its chassis.
    static func forDevicePID(_ pid: Int?) -> RazerMouseSilhouette {
        switch pid {
        case 0x00DB, 0x00DA, 0x00AF, 0x00B0: return .cobraPro // Cobra HyperSpeed + Cobra Pro
        case 0x0062: return .atheris
        default: return .cobra
        }
    }
}

/// Draws a Razer-style "tri-snake" mark: three curved blades radiating from the centre at
/// 120°. This is an original, evocative mark — the actual Razer logo is a trademark.
enum MenuBarIcon {

    /// A template image for the menu bar (monochrome; adapts to light/dark automatically).
    static func template(pointSize: CGFloat = 16) -> NSImage {
        let img = draw(size: pointSize) { ctx, _ in ctx.setStrokeColor(NSColor.black.cgColor) }
        img.isTemplate = true
        return img
    }

    /// A coloured version (for previews / about screens).
    static func colored(pointSize: CGFloat, color: NSColor = NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1)) -> NSImage {
        draw(size: pointSize) { ctx, _ in ctx.setStrokeColor(color.cgColor) }
    }

    private static func draw(size: CGFloat, _ configure: @escaping (CGContext, NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            configure(ctx, rect)

            let c = CGPoint(x: rect.midX, y: rect.midY)
            let s = size
            let outer = s * 0.40
            ctx.setLineWidth(s * 0.135)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Three identical curved snakes, each rotated 120°.
            for k in 0..<3 {
                let base = CGFloat(k) * (2 * .pi / 3) - .pi / 2 // point one snake up
                let perp = base + .pi / 2

                func pt(_ alongFrac: CGFloat, _ sideFrac: CGFloat) -> CGPoint {
                    CGPoint(
                        x: c.x + cos(base) * outer * alongFrac + cos(perp) * s * sideFrac,
                        y: c.y + sin(base) * outer * alongFrac + sin(perp) * s * sideFrac
                    )
                }

                let path = CGMutablePath()
                path.move(to: pt(0.10, -0.02))
                // S-curve: swing out one side then hook back — snake-like.
                path.addCurve(to: pt(1.0, 0.06),
                              control1: pt(0.35, 0.20),
                              control2: pt(0.85, 0.20))
                ctx.addPath(path)
                ctx.strokePath()
            }
            return true
        }
    }

    /// A mouse silhouette with a small Razer triskelion cut into the body (even-odd).
    /// Template image for the menu bar.
    static func mouse(pointSize: CGFloat = 16, razerCutout: Bool = true) -> NSImage {
        let img = drawMouse(size: pointSize, razerCutout: razerCutout, silhouette: .cobra)
        img.isTemplate = true
        return img
    }

    /// Same silhouette family, but shaped/detailed to match the specific connected model
    /// (by USB product ID) instead of always drawing the generic Cobra body. Falls back to
    /// the generic Cobra shape for an unknown or absent device.
    static func mouseModel(pid: Int?, razerCutout: Bool = true, pointSize: CGFloat = 20) -> NSImage {
        let img = drawMouse(size: pointSize, razerCutout: razerCutout, silhouette: RazerMouseSilhouette.forDevicePID(pid))
        img.isTemplate = true
        return img
    }

    private static func drawMouse(size s: CGFloat, razerCutout: Bool, silhouette: RazerMouseSilhouette, color: NSColor = .black) -> NSImage {
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

            // Button-split line below the wheel.
            ctx.move(to: P(0, 0.13))
            ctx.addLine(to: P(0, -0.10))

            // Thumb buttons on the left edge: two on Cobra/Cobra Pro, one on the smaller Atheris.
            let bw = s * 0.115, bh = s * 0.072
            let thumbYs: [CGFloat] = silhouette == .atheris ? [0.12] : [0.175, 0.065]
            for yy in thumbYs {
                let r = CGRect(x: cx - 0.405 * scale * s, y: cy + yy * scale * s - bh / 2, width: bw, height: bh)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: bh * 0.45, cornerHeight: bh * 0.45, transform: nil))
            }

            // Cobra Pro/HyperSpeed add a visible on-the-fly DPI clutch button behind the wheel.
            if silhouette == .cobraPro {
                let dpi = CGRect(x: cx - wheelW * 0.55, y: cy - 0.02 * s, width: wheelW * 1.1, height: s * 0.05)
                ctx.addPath(CGPath(roundedRect: dpi, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
            }
            ctx.strokePath()

            // Triskelion mark near the base.
            if razerCutout {
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
    static func writePreview(to path: String, size: CGFloat, silhouette: RazerMouseSilhouette = .cobra, razerCutout: Bool = true) {
        let image = drawMouse(size: size, razerCutout: razerCutout, silhouette: silhouette, color: NSColor(red: 0x44/255, green: 0xD6/255, blue: 0x2C/255, alpha: 1))
        let px = Int(size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Dark backdrop so the mark is visible in the preview.
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
