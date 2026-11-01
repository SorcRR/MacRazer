// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

// MARK: Shared lighting controls

/// The popover's colour swatches, mouse and accessories alike. Distinct hues with a true red
/// (SwiftUI .red is a warm orange-red; .green duplicated razerGreen). Each carries its
/// spoken/tooltip name.
let lightingSwatches: [(name: String, color: Color)] = [
    ("Red", .swatchRed),
    ("Orange", Color(red: 1.0, green: 0.5, blue: 0.0)),
    ("Yellow", .swatchYellow),
    ("Green", .razerGreen),
    ("Cyan", .swatchCyan),
    ("Blue", .swatchBlue),
    ("Purple", Color(red: 0.6, green: 0.2, blue: 1.0)),
    ("Pink", Color(red: 1.0, green: 0.2, blue: 0.65)),
]

/// A real button rather than a tap gesture on a circle, so it reaches VoiceOver and
/// keyboard navigation, and greys out with the rest of the card while disconnected.
struct SwatchButton: View {
    let color: Color
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .overlay(Circle().inset(by: -2.5).stroke(Color.primary, lineWidth: selected ? 1.5 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Circular "custom colour" well: a rainbow ring that opens the colour page.
struct CustomColorWell: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                    center: .center))
                Image(systemName: "eyedropper").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Pick any colour")
        .accessibilityLabel("Custom colour")
    }
}

/// Wave speed, slow on the left and fast on the right, shown only while Wave runs. Sent
/// when the drag ends, like brightness.
struct WaveSpeedSlider: View {
    @Binding var value: Double
    let onCommit: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tortoise.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: $value, in: 0...1) { editing in
                if !editing { onCommit(value) }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            .accessibilityLabel("Wave speed")
            .accessibilityValue(WaveSpeed.spokenValue(fromFraction: value))
            .scrollAdjusts($value, in: 0...1, onCommit: onCommit)
            Image(systemName: "hare.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// The brightness slider, sun to sun.
struct BrightnessSlider: View {
    @Binding var value: Double
    let onCommit: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: $value, in: 0...100, step: 1) { editing in
                if !editing { onCommit(Int(value)) }
            }
            .tint(.razerGreen)
            .controlSize(.small)
            .scrollAdjusts($value, in: 0...100, snap: 1) { onCommit(Int($0)) }
            Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A small orange tag after a device's name: MacRazer hasn't been tried on it.
struct UntestedBadge: View {
    var body: some View {
        Text("UNTESTED")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.batteryMid)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.batteryMid.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .help("Shares a tested model's commands, but nobody has tried MacRazer on this one yet.")
    }
}

// MARK: Accessory card

/// One Razer accessory under "Other Razer devices". Closed, it is one line: name, a colour
/// dot and what it's running. Open, its own lighting controls follow, or the question of who
/// sets its colours while Synapse runs. Whether it's open is remembered per model.
struct AccessoryCard: View {
    @ObservedObject var accessory: AccessoryController
    /// A mouse is there to follow. Without one the switch goes and the card's own controls
    /// come back, so a "Follow mouse" left on can't hide them.
    let hasMouse: Bool
    /// What the mouse's light shows, for the icon and the dot while following it.
    let mouseGlow: AccessoryIcon.Glow
    /// Opens the colour page for this accessory.
    let onPickColor: () -> Void

    @AppStorage private var expanded: Bool
    /// Local mirrors of the controller's values, so the sliders move while dragged and snap
    /// back on a failed write.
    @State private var brightness: Double
    @State private var waveSpeed: Double

    /// `startsOpen` applies until the person opens or closes the card once.
    init(accessory: AccessoryController, hasMouse: Bool, mouseGlow: AccessoryIcon.Glow, startsOpen: Bool,
         onPickColor: @escaping () -> Void) {
        self.accessory = accessory
        self.hasMouse = hasMouse
        self.mouseGlow = mouseGlow
        self.onPickColor = onPickColor
        _expanded = AppStorage(wrappedValue: startsOpen, "popoverAccessoryExpanded.\(accessory.info.pid)")
        _brightness = State(initialValue: Double(accessory.lighting.brightness))
        _waveSpeed = State(initialValue: WaveSpeed.fraction(fromByte: accessory.lighting.waveSpeed ?? WaveSpeed.standard))
    }

    private var info: RazerAccessoryInfo { accessory.info }
    private var following: Bool { accessory.followsMouse && hasMouse && accessory.canWrite }

    var body: some View {
        cardSurface(VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: { header }
            .buttonStyle(.plain)
            .accessibilityLabel("\(info.name), \(info.kind.label)")
            .accessibilityValue(subtitle)
            .accessibilityHint(expanded ? "Hides its lighting" : "Shows its lighting")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if accessory.synapseRunning { synapseToggleRow }
                    if accessory.canWrite { controls }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading))
        .onChange(of: accessory.lighting) { _, new in syncSliders(new) }
        // A failed write leaves `lighting` as it was, so snap the sliders back explicitly.
        .onChange(of: accessory.lastWriteFailure) { _, _ in syncSliders(accessory.lighting) }
    }

    private func syncSliders(_ lighting: AccessoryLighting) {
        brightness = Double(lighting.brightness)
        waveSpeed = WaveSpeed.fraction(fromByte: lighting.waveSpeed ?? WaveSpeed.standard)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AccessoryIcon(kind: info.kind, glow: glow)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(info.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !info.verified { UntestedBadge() }
                }
                HStack(spacing: 5) {
                    if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    /// What its light shows: the mouse's while following, else its own. Unlit while Synapse
    /// has it or before MacRazer has set an effect: there's nothing known to draw.
    private var glow: AccessoryIcon.Glow {
        if accessory.leftToSynapse { return .unlit }
        if following { return mouseGlow }
        guard let effect = accessory.lighting.effect, accessory.lighting.brightness > 0 else { return .unlit }
        return AccessoryIcon.Glow(effect: effect, color: accessory.lighting.color.swiftUIColor)
    }

    /// The colour by the subtitle, for an effect that has one.
    private var dot: Color? {
        if case .color(let color) = glow { return color }
        return nil
    }

    private var subtitle: String {
        if accessory.leftToSynapse { return "Colours set by Synapse" }
        if following { return "Following mouse" }
        return summary
    }

    /// The effect and brightness. Before MacRazer has set an effect it can only say the
    /// brightness: the accessory's own effect can't be read.
    private var summary: String {
        let pct = Int(brightness)
        guard let effect = accessory.lighting.effect else { return "\(pct)%" }
        if pct == 0 || effect == .off { return "Off" }
        return "\(effect.rawValue) · \(pct)%"
    }

    @ViewBuilder private var controls: some View {
        if hasMouse {
            HStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Follow mouse").font(.system(size: 11.5))
                Spacer(minLength: 6)
                Toggle("Follow mouse", isOn: $accessory.followsMouse)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.razerGreen)
                    .controlSize(.mini)
            }
        }
        if !following { lightingControls }
    }

    /// The mouse's lighting controls, pointed at this accessory.
    @ViewBuilder private var lightingControls: some View {
        BrightnessSlider(value: $brightness) { accessory.setBrightness($0) }
        // nil (never set from MacRazer) shows no segment picked rather than a guess.
        Picker("", selection: Binding(get: { accessory.lighting.effect },
                                      set: { if let e = $0 { accessory.setEffect(e) } })) {
            ForEach(info.effects) { Text($0.rawValue).tag(Optional($0)) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        if accessory.lighting.effect == .wave {
            WaveSpeedSlider(value: $waveSpeed) { accessory.setWaveSpeed(WaveSpeed.byte(fromFraction: $0)) }
                .transition(.opacity)
        }
        // Always there, unlike the mouse's: picking a colour under Spectrum or Wave switches
        // to Static, so the colours are one click away whatever it is running. Only Static
        // and Breathing show a colour as picked.
        HStack(spacing: 7) {
            ForEach(lightingSwatches.indices, id: \.self) { i in
                let sw = lightingSwatches[i]
                SwatchButton(color: sw.color, name: sw.name, selected: isSelected(sw.color)) {
                    accessory.setColor(sw.color.rgb)
                }
            }
            CustomColorWell(action: onPickColor)
            Spacer(minLength: 0)
        }
        if info.verified, let effect = accessory.lighting.effect, !info.isTested(effect) {
            Label("\(effect.rawValue) hasn't been tried on this \(info.kind.label.lowercased()) yet.",
                  systemImage: "questionmark.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isSelected(_ color: Color) -> Bool {
        accessory.lighting.effect?.usesColor == true && color.rgb == accessory.lighting.color
    }

    /// Shown only while Synapse runs: who sets this accessory's colours, either way at any
    /// time. Off, the default, leaves them to Synapse and hides MacRazer's controls; on,
    /// MacRazer's colours go back on, and again after a wake or reconnect.
    private var synapseToggleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use MacRazer").font(.system(size: 11.5, weight: .medium))
                Text("Razer Synapse is running and may change this \(info.kind.label.lowercased())'s colours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle("Use MacRazer", isOn: Binding(get: { accessory.owner == .macRazer },
                                                 set: { accessory.choose($0 ? .macRazer : .synapse) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.razerGreen)
                .controlSize(.mini)
        }
    }
}

// MARK: Accessory icon

/// A small drawing of the accessory in its card's tile, lit the way the real one is: keys or
/// the pad's edge in its colour, a rainbow for Spectrum and Wave, plain while off or unknown.
/// Tinted like the mouse's tile in the header, so the devices read as one family.
struct AccessoryIcon: View {
    enum Glow: Equatable {
        case color(Color)
        case rainbow
        case unlit

        init(effect: LightingEffect, color: Color) {
            switch effect {
            case .staticColor, .breathing: self = .color(color)
            case .spectrum, .wave: self = .rainbow
            case .off: self = .unlit
            }
        }
    }

    let kind: AccessoryKind
    let glow: Glow

    private static let rainbow = [Color.red, .orange, .yellow, .green, .cyan, .blue, .purple]

    /// The tile behind the drawing: the light's colour, faint, or the plain grey tile.
    private var tile: Color {
        switch glow {
        case .color(let color): return color.opacity(0.20)
        case .rainbow: return Color.primary.opacity(0.12)
        case .unlit: return Color.primary.opacity(0.10)
        }
    }

    var body: some View {
        Canvas { context, size in
            switch kind {
            case .keyboard: drawKeyboard(in: &context, size: size)
            case .mousepad: drawMousepad(in: &context, size: size)
            }
        }
        .frame(width: 24, height: 24)
        .frame(width: 34, height: 34)
        .background(tile, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }

    private func shading(across rect: CGRect) -> GraphicsContext.Shading {
        switch glow {
        case .color(let color): return .color(color)
        case .rainbow:
            return .linearGradient(Gradient(colors: Self.rainbow),
                                   startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                   endPoint: CGPoint(x: rect.maxX, y: rect.midY))
        case .unlit: return .color(.primary.opacity(0.55))
        }
    }

    /// A tenkeyless board seen from above: the case, three rows of keys and a space bar.
    private func drawKeyboard(in context: inout GraphicsContext, size: CGSize) {
        let body = CGRect(x: 0.5, y: 5, width: size.width - 1, height: 14)
        context.fill(Path(roundedRect: body, cornerRadius: 2.5), with: .color(.primary.opacity(0.18)))
        context.stroke(Path(roundedRect: body, cornerRadius: 2.5), with: .color(.primary.opacity(0.85)), lineWidth: 1)
        let keys = shading(across: body)
        // Seven keys to a row, sized to fit inside the case's 1.7 pt margins.
        let gap: CGFloat = 0.8, inset: CGFloat = 1.7
        let left = body.minX + inset, right = body.maxX - inset
        let pitch = (right - left + gap) / 7, key = pitch - gap
        func keyCap(_ x: CGFloat, _ y: CGFloat, width: CGFloat) {
            context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: key), cornerRadius: 0.5), with: keys)
        }
        for (row, count) in [7, 7, 6].enumerated() {
            let y = body.minY + 1.6 + CGFloat(row) * pitch
            // The third row starts half a key in, the way a real board's rows step.
            let indent = row == 2 ? pitch / 2 : 0
            for i in 0..<count { keyCap(left + indent + CGFloat(i) * pitch, y, width: key) }
        }
        // Bottom row: a modifier each side of the space bar.
        let bottom = body.minY + 1.6 + 3 * pitch
        let modifier = key * 1.5
        keyCap(left, bottom, width: modifier)
        keyCap(left + modifier + gap, bottom, width: right - left - 2 * (modifier + gap))
        keyCap(right - modifier, bottom, width: modifier)
    }

    /// A hard pad seen at a slight angle: its surface, the lit edge all round, the logo near
    /// the top and the cable leaving the far corner.
    private func drawMousepad(in context: inout GraphicsContext, size: CGSize) {
        let pad = CGRect(x: 1, y: 5.5, width: size.width - 2, height: 15)
        let outline = Path(roundedRect: pad, cornerRadius: 3)
        context.fill(outline, with: .color(.primary.opacity(0.22)))
        // The light: a soft halo, then the edge itself.
        var halo = context
        halo.addFilter(.blur(radius: 1.2))
        halo.stroke(outline, with: shading(across: pad), lineWidth: 2.2)
        context.stroke(outline, with: shading(across: pad), lineWidth: 1.3)
        // Logo, near the top edge.
        let logo = CGRect(x: pad.midX - 1.6, y: pad.minY + 2.2, width: 3.2, height: 3.2)
        context.fill(Path(ellipseIn: logo), with: shading(across: pad))
        // Cable, out of the top right corner.
        var cable = Path()
        cable.move(to: CGPoint(x: pad.maxX - 3, y: pad.minY))
        cable.addCurve(to: CGPoint(x: pad.maxX + 0.5, y: 0.5),
                       control1: CGPoint(x: pad.maxX - 3, y: pad.minY - 2.5),
                       control2: CGPoint(x: pad.maxX, y: 2.5))
        context.stroke(cable, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}
