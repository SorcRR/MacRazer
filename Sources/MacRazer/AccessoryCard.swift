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
    /// The mouse's colour, for the dot while following it; nil when its effect has no colour.
    let mouseColor: Color?
    /// Opens the colour page for this accessory.
    let onPickColor: () -> Void

    @AppStorage private var expanded: Bool
    /// Local mirrors of the controller's values, so the sliders move while dragged and snap
    /// back on a failed write.
    @State private var brightness: Double
    @State private var waveSpeed: Double

    /// `startsOpen` applies until the person opens or closes the card once.
    init(accessory: AccessoryController, hasMouse: Bool, mouseColor: Color?, startsOpen: Bool,
         onPickColor: @escaping () -> Void) {
        self.accessory = accessory
        self.hasMouse = hasMouse
        self.mouseColor = mouseColor
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
            Image(systemName: info.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
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

    /// The colour it shows: the mouse's while following, else its own, and none for an
    /// effect without one (Spectrum, Wave, Off) or one MacRazer hasn't set.
    private var dot: Color? {
        if accessory.leftToSynapse { return nil }
        if following { return mouseColor }
        guard let effect = accessory.lighting.effect, effect.usesColor else { return nil }
        return accessory.lighting.color.swiftUIColor
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
