// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import SwiftUI

/// The inputs of MacRazer's windows (the device test, the crash report), drawn alike. The
/// system's rounded-border field and segmented picker stay the height of their text whatever
/// their control size, too small to read or hit comfortably.
extension View {
    /// A one-line text field about 32 points high, drawn like the windows' comment boxes.
    func inputBox() -> some View { modifier(InputBox()) }

    /// A multi-line `TextEditor` drawn like `inputBox`, with `placeholder` while it's empty.
    func editorBox(placeholder: String, isEmpty: Bool, height: CGFloat = 80) -> some View {
        font(.system(size: 13))
            .frame(height: height)
            .padding(4)
            // The editor's own opaque background would sit as a flat box on a glass or tinted
            // window; a faint fill like the cards keeps it readable on all of them.
            .scrollContentBackground(.hidden)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.leading, 9).padding(.top, 5).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.15)))
    }
}

/// `inputBox`. The plain style it needs for its height draws no focus ring, so the border
/// turns Razer green while the field has the keyboard.
private struct InputBox: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(focused ? Color.razerGreenText : Color.primary.opacity(0.15), lineWidth: focused ? 1.5 : 1))
    }
}

/// A choice of a few options as equal-width buttons with an icon each, about 38 points high,
/// in place of a segmented picker. The selected one is outlined and tinted in Razer green.
/// Like the picker it replaces, the group takes keyboard focus as one control, the arrow keys
/// move the choice, and VoiceOver reads it as a segmented picker.
struct ChoiceButtons<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        /// An SF Symbol.
        let icon: String
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.icon).font(.system(size: 13, weight: .medium))
                        Text(option.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .foregroundStyle(selected ? Color.razerGreenText : Color.primary)
                    .background(selected ? Color.razerGreen.opacity(0.14) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.razerGreenText : Color.primary.opacity(0.15), lineWidth: selected ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func move(by step: Int) -> KeyPress.Result {
        guard let current = options.firstIndex(where: { $0.value == selection }) else {
            selection = options[0].value
            return .handled
        }
        let next = current + step
        guard options.indices.contains(next) else { return .ignored }
        selection = options[next].value
        return .handled
    }
}
