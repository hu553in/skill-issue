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
    let error: String
    let catalogError: String
    let retry: () -> Void

    private var messages: [String] { [error, catalogError].filter { !$0.isEmpty } }
    private var statusLabel: String { !working && !messages.isEmpty ? "Error" : status }
    private var statusColor: Color {
        if working { return .blue }
        if !messages.isEmpty { return Color(nsColor: SettingsColors.destructive) }
        return live ? .green : .secondary
    }
    private var statusIcon: String {
        if working { return "ellipsis" }
        if !messages.isEmpty { return "exclamationmark.circle.fill" }
        return live ? "waveform" : "checkmark.circle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            if !messages.isEmpty {
                SettingsErrorNotice(
                    messages: messages, retry: catalogError.isEmpty ? nil : retry,
                    retryDisabled: working || live)
            }
        }
        .onChange(of: messages, initial: true) { _, messages in
            guard !messages.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [
                    .announcement: messages.joined(separator: " "),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }
}

private struct SettingsErrorNotice: View {
    let messages: [String]
    let retry: (() -> Void)?
    let retryDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(nsColor: SettingsColors.destructive))
                .font(.body).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry).disabled(retryDisabled)
            }
        }
        .padding(12)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityLabel("Error")
    }
}
