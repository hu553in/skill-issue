import AppKit
import SwiftUI

enum SettingsColors {
    static let secondaryText = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.67, green: 0.67, blue: 0.67, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1)
    }
    static let link = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.31, green: 0.68, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0.39, blue: 0.70, alpha: 1)
    }
    // Small red labels need more contrast than system red on tinted controls.
    static let destructive = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(srgbRed: 0.6, green: 0.07, blue: 0.07, alpha: 1)
    }
}

struct SettingsHeader: View {
    #if !README_SCREENSHOTS
        private let version = AppBuild.releaseVersion ?? "local build"
    #endif
    let status: String
    let working: Bool
    let live: Bool
    let answering: Bool
    let canStart: Bool
    let error: String
    let catalogError: String
    let feedback: ChatGPTFailure?
    var failureStatus: String?
    var setupRequired = false
    private var hasMessage: Bool { !error.isEmpty || !catalogError.isEmpty }
    private var warning: Bool { hasMessage ? feedback?.isWarning ?? false : setupRequired }
    private var statusLabel: String {
        guard !working && hasMessage else { return status }
        if let failureStatus { return failureStatus }
        switch feedback?.recovery {
        case .signIn?: return "Sign in required"
        case .enablePlan?: return "Permission required"
        default: return warning ? "Warning" : "Error"
        }
    }
    private var statusColor: Color {
        if working { return .blue }
        if warning { return .orange }
        if hasMessage { return Color(nsColor: SettingsColors.destructive) }
        if answering { return .blue }
        return live ? .green : .secondary
    }
    private var statusIcon: String {
        if working { return "ellipsis" }
        if warning { return "exclamationmark.triangle.fill" }
        if hasMessage { return "exclamationmark.circle.fill" }
        if answering { return "ellipsis" }
        return live ? "waveform" : canStart ? "checkmark.circle" : "person.crop.circle"
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsLayout.spacing) {
            HStack(spacing: SettingsLayout.compactSpacing) {
                Image(systemName: "tortoise.fill").font(.title2)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.spacing) {
                    Text("Skill Issue").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    #if !README_SCREENSHOTS
                        Text(version).font(.subheadline)
                            .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                            .accessibilityLabel(
                                AppBuild.releaseVersion == nil
                                    ? "Local build" : "Version \(version)")
                    #endif
                }
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

struct SettingsNotice: View {
    let messages: [String]
    let warning: Bool
    let diagnostic: String
    let actionTitle: String?
    let actionDisabled: Bool
    let action: () -> Void
    let retryModels: (() -> Void)?
    let retryModelsDisabled: Bool
    @Binding var detailsExpanded: Bool
    var disabledHelp = ""

    var body: some View {
        HStack(alignment: .center, spacing: SettingsLayout.spacing) {
            Image(
                systemName: warning
                    ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
            )
            .foregroundStyle(warning ? .orange : Color(nsColor: SettingsColors.destructive))
            .font(.body).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SettingsLayout.compactSpacing) {
                ForEach(messages, id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
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
                VStack(spacing: SettingsLayout.compactSpacing) {
                    if let actionTitle {
                        Button(actionTitle, action: action).disabled(actionDisabled)
                            .help(actionDisabled ? disabledHelp : "")
                    }
                    if let retryModels {
                        Button("Retry", action: retryModels).disabled(retryModelsDisabled)
                            .help(retryModelsDisabled ? disabledHelp : "")
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
