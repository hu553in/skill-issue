import SwiftUI

struct SettingsControls: View {
    let live: Bool
    let canAnswer: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let fontSize: Int
    let canChangeTextSize: Bool
    let modifiers: ShortcutModifiers
    let canChangeModifiers: Bool
    let changeModifiersHelp: String
    let answer: () -> Void
    let navigate: (Int) -> Void
    let scroll: (Int) -> Void
    let zoom: (Int) -> Void
    let changeModifiers: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: SettingsLayout.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.spacing) {
                    Text("Controls").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Hold")
                        ShortcutModifierSymbols(modifiers: modifiers)
                    }.font(.subheadline)
                        .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                        .accessibilityElement(children: .combine)
                    Button("Change…", action: changeModifiers).disabled(!canChangeModifiers)
                        .help(changeModifiersHelp)
                        .accessibilityLabel("Change shortcut modifiers")
                }
                if live {
                    answerButton.buttonStyle(.borderedProminent)
                } else {
                    answerButton
                }
                HStack(spacing: SettingsLayout.spacing) {
                    shortcutButton("Previous answer", key: .left, enabled: canGoBack) {
                        navigate(-1)
                    }
                    shortcutButton("Next answer", key: .right, enabled: canGoForward) {
                        navigate(1)
                    }
                }
                HStack(spacing: SettingsLayout.spacing) {
                    shortcutButton("Read up", key: .up, enabled: live) { scroll(-1) }
                    shortcutButton("Read down", key: .down, enabled: live) { scroll(1) }
                }
                HStack(spacing: SettingsLayout.spacing) {
                    shortcutButton(
                        "Decrease text size", key: .minus,
                        enabled: canChangeTextSize && fontSize > fontSizeRange.lowerBound
                    ) { zoom(-1) }
                    shortcutButton(
                        "Increase text size", key: .plus,
                        enabled: canChangeTextSize && fontSize < fontSizeRange.upperBound
                    ) { zoom(1) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ControlsGroupBoxStyle())
        .buttonStyle(.bordered)
    }

    private var answerButton: some View {
        shortcutButton("Request answer", key: .space, enabled: canAnswer, action: answer)
    }

    private func shortcutButton(
        _ title: String, key: ShortcutKey, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            shortcutLabel(title, key: key)
        }
        .disabled(!enabled)
        // The tooltip doubles as the accessibility hint, so it keeps the shortcut while live.
        .help(
            live || key == .minus || key == .plus ? key.hint(modifiers) : "Start a session first."
        )
        .accessibilityLabel(title)
    }

    private func shortcutLabel(_ title: String, key: ShortcutKey) -> some View {
        HStack(spacing: SettingsLayout.spacing) {
            Text(title)
            Spacer(minLength: 8)
            ShortcutHint(key: key).opacity(0.75).accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
    }
}

private struct ControlsGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayout.spacing) {
            configuration.label
            configuration.content
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
