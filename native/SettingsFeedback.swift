import AppKit
import SwiftUI

enum SettingsColors {
    // Small red labels need more contrast than system red on tinted controls.
    static let destructive = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(srgbRed: 0.6, green: 0.07, blue: 0.07, alpha: 1)
    }
}

struct SettingsHeader: View {
    let status: String
    let working: Bool
    let live: Bool
    let answering: Bool
    let canStart: Bool
    let error: String
    let catalogError: String
    let feedback: ChatGPTFailure?
    private var hasMessage: Bool { !error.isEmpty || !catalogError.isEmpty }
    private var warning: Bool { feedback?.isWarning ?? false }
    private var statusLabel: String {
        guard !working && hasMessage else { return status }
        switch feedback?.recovery {
        case .signIn?: return "Sign in required"
        case .enablePlan?: return "Permission required"
        default: return warning ? "Warning" : "Error"
        }
    }
    private var statusColor: Color {
        if working { return .blue }
        if hasMessage && warning { return .orange }
        if hasMessage { return Color(nsColor: SettingsColors.destructive) }
        if answering { return .blue }
        return live ? .green : .secondary
    }
    private var statusIcon: String {
        if working { return "ellipsis" }
        if hasMessage && warning { return "exclamationmark.triangle.fill" }
        if hasMessage { return "exclamationmark.circle.fill" }
        if answering { return "ellipsis" }
        return live ? "waveform" : canStart ? "checkmark.circle" : "person.crop.circle"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill").font(.title2)
                    .accessibilityHidden(true)
                Text("Skill Issue").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }.layoutPriority(1)
            Spacer(minLength: 0)
            Label {
                Text(statusLabel).foregroundStyle(.primary)
                    .accessibilityLabel("Status: \(statusLabel)")
            } icon: {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(statusColor.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsErrorNotice: View {
    let messages: [String]
    let warning: Bool
    let diagnostic: String
    let actionTitle: String?
    let actionHint: String
    let actionDisabled: Bool
    let action: () -> Void
    let retryModels: (() -> Void)?
    let retryModelsDisabled: Bool
    @Binding var detailsExpanded: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(
                systemName: warning
                    ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
            )
            .foregroundStyle(warning ? .orange : Color(nsColor: SettingsColors.destructive))
            .font(.body).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !actionHint.isEmpty {
                    Text(actionHint).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !diagnostic.isEmpty {
                    DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                        Text(diagnostic).font(.caption).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if actionTitle != nil || retryModels != nil {
                VStack(spacing: 8) {
                    if let actionTitle {
                        Button(actionTitle, action: action).disabled(actionDisabled)
                    }
                    if let retryModels {
                        Button("Retry", action: retryModels).disabled(retryModelsDisabled)
                    }
                }
            }
        }
        .padding(12)
        .background(
            (warning ? Color.orange : .red).opacity(0.10), in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain).accessibilityLabel(warning ? "Warning" : "Error")
    }
}
