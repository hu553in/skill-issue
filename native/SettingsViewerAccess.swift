import AppKit
import SwiftUI

struct ViewerAccessConfiguration: View {
    let origin: String
    let save: (ViewerAccessCredentials) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clientID: String
    @State private var clientSecret: String
    @State private var secretVisible = false
    @State private var error = ""
    private enum Field: Hashable { case clientID, hiddenSecret, visibleSecret }
    @FocusState private var focused: Field?

    init(
        origin: String, credentials: ViewerAccessCredentials?,
        save: @escaping (ViewerAccessCredentials) throws -> Void
    ) {
        self.origin = origin
        self.save = save
        let matching = credentials.flatMap { $0.origin == origin ? $0 : nil }
        _clientID = State(initialValue: matching?.clientID ?? "")
        _clientSecret = State(initialValue: matching?.clientSecret ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Cloudflare Access").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(origin).font(.subheadline)
                .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !error.isEmpty {
                SettingsNotice(
                    messages: [error], warning: false, diagnostic: "", actionTitle: nil,
                    actionDisabled: false, action: {}, retryModels: nil,
                    retryModelsDisabled: true, detailsExpanded: .constant(false))
            }
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Client ID") {
                    TextField("", text: $clientID).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .clientID)
                        .accessibilityLabel("Client ID")
                }
                LabeledContent("Client secret") {
                    HStack(spacing: 8) {
                        if secretVisible {
                            TextField("", text: $clientSecret).textFieldStyle(.roundedBorder)
                                .focused($focused, equals: .visibleSecret)
                                .accessibilityLabel("Client secret")
                        } else {
                            SecureField("", text: $clientSecret).textFieldStyle(.roundedBorder)
                                .focused($focused, equals: .hiddenSecret)
                                .accessibilityLabel("Client secret")
                        }
                        Button {
                            secretVisible.toggle()
                            Task { @MainActor in
                                await Task.yield()
                                focused = secretVisible ? .visibleSecret : .hiddenSecret
                            }
                        } label: {
                            Image(systemName: secretVisible ? "eye.slash" : "eye")
                                .frame(width: 18, height: 18)
                        }
                        .accessibilityLabel(
                            secretVisible ? "Hide client secret" : "Show client secret"
                        )
                        .help(secretVisible ? "Hide client secret" : "Show client secret")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            Text(
                "Use a service token for this Mac and an email policy for browser sign-in. Credentials stay in Keychain."
            ).font(.callout).foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                SettingsLink(
                    title: "Read the setup guide",
                    destination: URL(
                        string: "https://github.com/hu553in/skill-issue#cloudflare-access")!
                )
                SettingsLink(
                    title: "Open Access applications",
                    destination: URL(
                        string:
                            "https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fone%2Faccess-controls%2Fapps"
                    )!
                )
                SettingsLink(
                    title: "Open service tokens",
                    destination: URL(
                        string:
                            "https://dash.cloudflare.com/?to=%2F%3Aaccount%2Fone%2Faccess-controls%2Fservice-credentials%2Fservice-tokens"
                    )!
                )
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: saveCredentials).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 468)
        .onAppear { focused = .clientID }
        .onChange(of: error) { _, message in
            guard !message.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    private func saveCredentials() {
        let identifier = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            error = "Enter the Client ID from your Cloudflare service token."
            focused = .clientID
            return
        }
        guard !secret.isEmpty else {
            error = "Enter the Client secret from your Cloudflare service token."
            focused = secretVisible ? .visibleSecret : .hiddenSecret
            return
        }
        do {
            let credentials = ViewerAccessCredentials(
                origin: origin, clientID: identifier, clientSecret: secret)
            try credentials.validate(for: ViewerEndpoint(origin))
            try save(credentials)
            dismiss()
        } catch {
            switch error as? ViewerFailure {
            case .invalidClientID?: focused = .clientID
            case .invalidClientSecret?: focused = secretVisible ? .visibleSecret : .hiddenSecret
            default: break
            }
            self.error =
                (error as? ViewerFailure)?.message ?? ViewerFailure.credentialsNotSaved.message
        }
    }
}
