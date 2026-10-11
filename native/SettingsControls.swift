import SwiftUI

struct SettingsControls: View {
    let live: Bool
    let canAnswer: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let fontSize: Int
    let answer: () -> Void
    let navigate: (Int) -> Void
    let scroll: (Int) -> Void
    let zoom: (Int) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if live {
                    answerButton.buttonStyle(.borderedProminent)
                } else {
                    answerButton
                }
                HStack(spacing: 12) {
                    shortcutButton("Previous answer", key: .left, enabled: canGoBack) {
                        navigate(-1)
                    }
                    shortcutButton("Next answer", key: .right, enabled: canGoForward) {
                        navigate(1)
                    }
                }
                HStack(spacing: 12) {
                    shortcutButton("Read up", key: .up, enabled: live) { scroll(-1) }
                    shortcutButton("Read down", key: .down, enabled: live) { scroll(1) }
                }
                HStack(spacing: 12) {
                    shortcutButton(
                        "Decrease text size", key: .minus,
                        enabled: live && fontSize > fontSizeRange.lowerBound
                    ) { zoom(-1) }
                    shortcutButton(
                        "Increase text size", key: .plus,
                        enabled: live && fontSize < fontSizeRange.upperBound
                    ) { zoom(1) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Controls").font(.headline).accessibilityAddTraits(.isHeader)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Hold")
                    ShortcutModifiers()
                }.font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
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
        .accessibilityLabel(title)
        .accessibilityHint(key.hint)
    }

    private func shortcutLabel(_ title: String, key: ShortcutKey) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            ShortcutHint(key: key).opacity(0.75).accessibilityHidden(true)
        }.frame(maxWidth: .infinity)
    }
}

private struct ControlsGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
