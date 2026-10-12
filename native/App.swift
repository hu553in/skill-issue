import AVFoundation
import AppKit
import Carbon
import CoreImage.CIFilterBuiltins
import SwiftUI

private struct AnswerLanguage: Decodable, Sendable {
    let name: String
    let label: String
    // The language list is a required bundled application resource.
    // swiftlint:disable:next force_try
    static let all = try! JSONDecoder().decode(
        [Self].self,
        from: Data(
            contentsOf:
                Bundle.module.url(
                    forResource: "answer-languages", withExtension: "json",
                    subdirectory: "Resources")!))
}

@MainActor
final class Model: ObservableObject {
    @Published var relayURL: String
    @Published var microphone: String
    @Published var language: String
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var modelSlug = ""
    @Published private(set) var reasoningEffort = ""
    @Published private(set) var catalogError = ""
    @Published private(set) var feedback: ChatGPTFailure?
    @Published var account = ""
    @Published var link: URL?
    private enum Operation {
        case restoringAccounts, signingIn, requestingPermission, signingOut, loadingModels
        case preparingSpeech(String)
        case starting(String)
        case stopping

        var label: String {
            switch self {
            case .restoringAccounts: return "Restoring accounts…"
            case .signingIn: return "Signing in…"
            case .requestingPermission: return "Waiting for permission…"
            case .signingOut: return "Signing out…"
            case .loadingModels: return "Loading models…"
            case .preparingSpeech(let label), .starting(let label): return label
            case .stopping: return "Stopping…"
            }
        }
    }
    @Published private var operation: Operation?
    var working: Bool { operation != nil }
    var status: String {
        if let operation { return operation.label }
        if state.live { return answering ? "Thinking…" : "Listening" }
        if account.isEmpty { return "Signed out" }
        if chatGPT.requiresSignIn { return "Sign in required" }
        if needsPlanPermission { return "Permission required" }
        return canStartSession ? "Ready" : "Unavailable"
    }
    var loadingModels: Bool {
        if case .loadingModels = operation { return true }
        return false
    }
    var modelPlaceholder: String {
        if loadingModels { return "Loading…" }
        if case .restoringAccounts = operation { return "Restoring accounts…" }
        if !chatGPT.accountsRestored { return "Unavailable" }
        if account.isEmpty { return "Sign in first" }
        return needsPlanPermission ? "Enable plan usage first" : "Unavailable"
    }
    var effortPlaceholder: String { loadingModels ? "Loading…" : "Not available" }
    @Published var viewerStatus = "Open the viewer on your phone."
    @Published private(set) var viewerDelivery = ""
    @Published var iconVisible = true
    @Published var error = ""
    @Published var state = ViewState()
    private let chatGPT: ChatGPT
    private let defaults: UserDefaults
    private let capture = Capture()
    private var relay: Relay?
    private var history = InterviewHistory()
    private var sessionID = UUID()
    private var currentRequest: String?
    private var answerTask: Task<Void, Never>?
    private var snapshotTask: Task<Observation, Error>?
    private var publishTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var terminating = false
    private var captureFailure: UUID?
    private var canUseChatGPT: Bool {
        !account.isEmpty && chatGPT.canUsePlan && !chatGPT.requiresSignIn
    }
    var canAnswer: Bool { state.live && !working && canUseChatGPT && selectedModel != nil }
    var needsPlanPermission: Bool { !account.isEmpty && !chatGPT.canUsePlan }
    var savedAccounts: [ChatGPTAccount] { chatGPT.registrations }
    var selectedAccountID: String { chatGPT.account?.clientID ?? "" }
    var activeAccountLabel: String {
        guard !account.isEmpty, let saved = chatGPT.account else { return account }
        return accountLabel(saved)
    }
    var canAuthenticate: Bool {
        !terminating && !working && !state.live && chatGPT.accountsRestored
    }
    var canChooseAccount: Bool { canAuthenticate && account.isEmpty }
    var selectedModel: ChatGPTModel? { models.first { $0.slug == modelSlug } }
    var answering: Bool { state.answers.contains { $0.status == "generating" } }
    var canSelectModel: Bool { !terminating && !working && !answering && !models.isEmpty }
    var canSelectEffort: Bool { canSelectModel && !(selectedModel?.efforts.isEmpty ?? true) }
    var canStartSession: Bool {
        guard !terminating, !working, !state.live, canUseChatGPT,
            let model = selectedModel
        else {
            return false
        }
        return model.supportsEffort(reasoningEffort)
    }

    init(chatGPT: ChatGPT = ChatGPT(), defaults: UserDefaults = .standard) {
        self.chatGPT = chatGPT
        self.defaults = defaults
        relayURL = defaults.string(forKey: "relayURL") ?? "http://127.0.0.1:8787"
        microphone = defaults.string(forKey: "microphone") ?? ""
        language = defaults.string(forKey: "language") ?? "English"
        let savedFontSize = defaults.integer(forKey: "fontSize")
        if fontSizeRange.contains(savedFontSize) { state.fontSize = savedFontSize }
        chatGPT.accountStateChanged = { [weak self] failure in
            guard let self else { return }
            self.syncAccount()
            if let failure { self.showError(failure) }
            self.publish()
        }
        restoreAccounts()
    }
    private func restoreAccounts() {
        guard !terminating, !working, !state.live else { return }
        operation = .restoringAccounts
        clearFeedback()
        settingsTask = Task {
            defer { finishSettings() }
            do {
                try await chatGPT.restore()
                try Task.checkCancellation()
                syncAccount()
                await loadModels()
            } catch {
                if !Task.isCancelled {
                    showError(
                        chatGPT.accountsRestored ? error : ChatGPTFailure.accountStorageUnavailable)
                }
            }
        }
    }
    func authenticate() {
        updateAuthentication(signingOut: chatGPT.isSignedIn)
    }
    func enablePlanUsage() {
        guard needsPlanPermission else { return }
        updateAuthentication(signingOut: false, requestPlanConsent: true)
    }
    func selectAccount(_ clientID: String) {
        guard canChooseAccount, clientID != selectedAccountID else { return }
        do {
            try chatGPT.selectAccount(clientID: clientID.isEmpty ? nil : clientID)
            clearFeedback()
            syncAccount()
        } catch { showError(error) }
    }
    func accountLabel(_ saved: ChatGPTAccount) -> String {
        guard savedAccounts.filter({ $0.email == saved.email }).count > 1,
            let index = savedAccounts.firstIndex(where: { $0.clientID == saved.clientID })
        else { return saved.email }
        return "\(saved.email) · Account \(index + 1)"
    }
    private func updateAuthentication(
        signingOut: Bool, requestPlanConsent: Bool = false
    ) {
        guard canAuthenticate else { return }
        operation =
            signingOut ? .signingOut : requestPlanConsent ? .requestingPermission : .signingIn
        clearFeedback()
        clearModels()
        settingsTask = Task {
            defer { finishSettings() }
            do {
                if signingOut {
                    let confirmed = try await chatGPT.signOut()
                    if !confirmed {
                        showError(ChatGPTFailure.remoteSignOutUnconfirmed)
                    }
                } else {
                    try await chatGPT.signIn(requestPlanConsent: requestPlanConsent)
                }
            } catch {
                if !Task.isCancelled { showError(error) }
                syncAccount()
                return
            }
            syncAccount()
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }
    func retryModels() {
        guard canRetryModels else { return }
        operation = .loadingModels
        clearFeedback()
        clearModels()
        settingsTask = Task {
            defer { finishSettings() }
            await loadModels()
        }
    }
    private func loadModels() async {
        guard !account.isEmpty else { return }
        guard chatGPT.canUsePlan else {
            showError(ChatGPTFailure.planDisabled)
            return
        }
        operation = .loadingModels
        do {
            let available = try await chatGPT.listModels()
            try Task.checkCancellation()
            let savedModel = defaults.string(forKey: "chatGPTModel")
            let selected =
                available.first { $0.slug == savedModel }
                ?? available.first { $0.slug == "gpt-6-luna" } ?? available[0]
            let savedEffort = defaults.string(forKey: "chatGPTReasoningEffort") ?? ""
            models = available
            modelSlug = selected.slug
            reasoningEffort =
                selected.slug == savedModel && selected.efforts.contains(savedEffort)
                ? savedEffort : selected.defaultEffort
            saveModelSelection()
        } catch {
            if !Task.isCancelled { showError(error, catalog: true) }
        }
    }
    private func syncAccount() {
        account = chatGPT.isSignedIn ? chatGPT.account?.email ?? "Connected" : ""
        if !chatGPT.isSignedIn || !chatGPT.canUsePlan { clearModels() }
    }
    private func clearFeedback() {
        error = ""
        catalogError = ""
        feedback = nil
        state.error = ""
    }
    var recovery: ChatGPTFailure.Recovery {
        if chatGPT.requiresSignIn { return .signIn }
        let recovery = feedback?.recovery ?? (catalogError.isEmpty ? .none : .retry)
        if case .retry = recovery, !chatGPT.isSignedIn { return .signIn }
        return recovery
    }
    var recoveryTitle: String? {
        switch recovery {
        case .restore, .save: return "Retry"
        case .signIn: return "Sign in again"
        case .enablePlan: return "Enable plan usage"
        case .usage: return "View usage"
        case .settings: return "Open ChatGPT"
        case .retry: return state.live ? "Request answer" : "Retry"
        case .configuration, .none: return nil
        }
    }
    var canRetryModels: Bool {
        !terminating && !working && !state.live && canUseChatGPT
    }
    var canRecover: Bool {
        switch recovery {
        case .restore: return !terminating && !working && !state.live
        case .save: return !terminating && !working
        case .signIn, .enablePlan: return !terminating && !working && !state.live
        case .usage, .settings: return true
        case .retry:
            return state.live ? canAnswer : canRetryModels
        case .configuration, .none: return false
        }
    }
    var recoveryHint: String {
        guard state.live else { return "" }
        switch recovery {
        case .signIn: return "Stop the session to sign in again."
        case .enablePlan: return "Stop the session to enable ChatGPT plan usage."
        default: return ""
        }
    }
    func recover() {
        guard canRecover else { return }
        switch recovery {
        case .restore: restoreAccounts()
        case .save:
            do {
                try chatGPT.savePendingAccounts()
                clearFeedback()
                syncAccount()
                if needsPlanPermission {
                    showError(ChatGPTFailure.planDisabled)
                } else if !state.live {
                    retryModels()
                }
                publish()
            } catch { showError(error) }
        case .signIn:
            updateAuthentication(signingOut: false, requestPlanConsent: false)
        case .enablePlan:
            updateAuthentication(signingOut: false, requestPlanConsent: true)
        case .usage:
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!)
        case .settings:
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
        case .retry:
            if state.live { answer() } else { retryModels() }
        case .configuration, .none: break
        }
    }
    private func clearModels() {
        models = []
        modelSlug = ""
        reasoningEffort = ""
        catalogError = ""
    }
    private func finishSettings() {
        settingsTask = nil
        operation = nil
    }
    func selectModel(_ slug: String) {
        guard canSelectModel, slug != modelSlug,
            let model = models.first(where: { $0.slug == slug })
        else { return }
        modelSlug = slug
        reasoningEffort = model.defaultEffort
        saveModelSelection()
    }
    func selectEffort(_ effort: String) {
        guard canSelectEffort, selectedModel?.efforts.contains(effort) == true else { return }
        reasoningEffort = effort
        saveModelSelection()
    }
    private func saveModelSelection() {
        defaults.set(modelSlug, forKey: "chatGPTModel")
        defaults.set(reasoningEffort, forKey: "chatGPTReasoningEffort")
    }
    func startSession() {
        guard canStartSession, let model = selectedModel else { return }
        let effort = reasoningEffort
        publishTask?.cancel()
        monitorTask?.cancel()
        cancelAnswer()
        operation = .preparingSpeech("Preparing speech…")
        clearFeedback()
        sessionID = UUID()
        let session = sessionID
        history = InterviewHistory()
        currentRequest = nil
        snapshotTask = nil
        captureFailure = nil
        state = ViewState(fontSize: state.fontSize, language: language)
        for (key, value) in [
            "relayURL": relayURL, "microphone": microphone, "language": language,
        ] { defaults.set(value, forKey: key) }
        startTask = Task { [self] in
            defer { startTask = nil }
            do {
                try Task.checkCancellation()
                try await capture.prepare { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.sessionID == session,
                            case .preparingSpeech = self.operation
                        else { return }
                        self.operation = .preparingSpeech(message)
                    }
                }
                try Task.checkCancellation()
                operation = .starting("Connecting ChatGPT…")
                try await chatGPT.prepareSession(model: model, effort: effort)
                try Task.checkCancellation()
                operation = .starting("Connecting viewer…")
                let relay = try await Relay.create(
                    url: relayURL.trimmingCharacters(in: .whitespacesAndNewlines))
                self.relay = relay
                link = relay.viewerURL
                try Task.checkCancellation()
                relay.onConnection = { [weak self] connected, count, applied in
                    guard let self, self.sessionID == session else { return }
                    self.viewerStatus =
                        !connected
                        ? "Reconnecting viewer…"
                        : count == 0
                            ? "Open the viewer on your phone." : "Viewer connected · \(count)"
                    self.viewerDelivery =
                        connected && count > 0
                        ? applied == count ? "Controls synced" : "Syncing controls…" : ""
                }
                operation = .starting("Starting capture…")
                try await capture.start(
                    microphone: microphone,
                    failed: { [weak self] in self?.captureFailed(session: session) })
                try Task.checkCancellation()
                guard captureFailure != session else { throw AppFailure.failed }
                state.live = true
                operation = nil
                state.canAnswer = canAnswer
                try relay.publish(state)
                publishTask = Task { [weak self] in
                    var previous = self?.state
                    var heartbeat = Date()
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(150))
                            guard let self, self.sessionID == session else { return }
                            self.state.canAnswer = self.canAnswer
                            if self.state != previous || Date().timeIntervalSince(heartbeat) >= 15 {
                                try relay.publish(self.state)
                                previous = self.state
                                heartbeat = Date()
                            }
                        } catch {
                            if !Task.isCancelled, let self, self.sessionID == session {
                                self.endSession(failed: true, error: error)
                            }
                            return
                        }
                    }
                }
                monitorTask = Task { await relay.monitor() }
            } catch {
                await endSession(failed: !Task.isCancelled, error: error).value
            }
        }
    }
    func stopSession() {
        guard !working, state.live || relay != nil else { return }
        endSession()
    }
    @discardableResult
    func endSession(failed: Bool = false, error: Error? = nil) -> Task<Void, Never> {
        if failed { showError(error ?? AppFailure.failed) }
        if let endingTask { return endingTask }
        operation = .stopping
        state.live = false
        cancelAnswer()
        sessionID = UUID()
        snapshotTask?.cancel()
        snapshotTask = nil
        publishTask?.cancel()
        publishTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        let old = relay
        relay = nil
        link = nil
        viewerStatus = "Open the viewer on your phone."
        viewerDelivery = ""
        let task = Task {
            async let stopped: Void = capture.stop()
            do { try await old?.close() } catch {
                if self.error.isEmpty && catalogError.isEmpty { showError(error) }
            }
            await stopped
            operation = nil
            endingTask = nil
        }
        endingTask = task
        return task
    }
    func answer() {
        guard canAnswer, let model = selectedModel else { return }
        let effort = reasoningEffort
        cancelAnswer()
        let id = UUID().uuidString
        let session = sessionID
        currentRequest = id
        state.beginAnswer(id: id)
        state.error = ""
        clearFeedback()
        let previous = snapshotTask
        // Both operations start at this key press. A newer request does not
        // cancel capture finalization or discard the older observation batch.
        let frozen = capture.freeze()
        let captured = Task { () throws -> Observation in
            async let image = try? capture.screenshot()
            for try await (cutoff, transcript) in frozen {
                let screenshot = await image
                return Observation(
                    requestID: id, cutoff: cutoff, transcript: transcript,
                    screenshot: screenshot?.0, screenshotTime: screenshot?.1)
            }
            throw AppFailure.failed
        }
        let snapshot = Task { () throws -> Observation in
            let observation = try await captured.value
            _ = try? await previous?.value
            guard sessionID == session else { throw CancellationError() }
            history.append(observation)
            return observation
        }
        snapshotTask = snapshot
        answerTask = Task {
            defer {
                if currentRequest == id {
                    answerTask = nil
                    publish()
                }
            }
            do {
                let observation = try await snapshot.value
                try Task.checkCancellation()
                guard observation.screenshot != nil, sessionID == session, currentRequest == id
                else { throw AppFailure.failed }
                let input = try history.input(through: id)
                try await chatGPT.answer(
                    input: input, language: language, model: model, effort: effort
                ) { [weak self] delta in
                    guard let self, self.sessionID == session, self.currentRequest == id,
                        let index = self.state.answers.firstIndex(where: { $0.id == id })
                    else { return }
                    self.state.answers[index].text += delta
                    self.history.update(
                        id, answer: self.state.answers[index].text, completed: false)
                }
                guard sessionID == session, currentRequest == id,
                    let index = state.answers.firstIndex(where: { $0.id == id })
                else { return }
                state.answers[index].status = "complete"
                history.update(id, answer: state.answers[index].text, completed: true)
            } catch {
                if !Task.isCancelled && sessionID == session && currentRequest == id {
                    if let index = state.answers.firstIndex(where: { $0.id == id }) {
                        state.answers[index].status = "failed"
                    }
                    showError(error)
                }
            }
        }
        publish()
    }
    private func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        if let id = currentRequest, let index = state.answers.firstIndex(where: { $0.id == id }),
            state.answers[index].status == "generating"
        {
            state.answers[index].status = "incomplete"
            history.update(id, answer: state.answers[index].text, completed: false)
        }
        currentRequest = nil
    }
    func navigate(_ direction: Int) {
        guard state.live else { return }
        state.select(direction)
        publish()
    }
    func scroll(_ direction: Int) {
        guard state.live else { return }
        state.scroll(direction)
        publish()
    }
    func zoom(_ direction: Int) {
        guard state.live else { return }
        let size = min(
            fontSizeRange.upperBound, max(fontSizeRange.lowerBound, state.fontSize + direction * 2))
        guard size != state.fontSize else { return }
        state.fontSize = size
        defaults.set(size, forKey: "fontSize")
        publish()
    }
    private func publish() {
        state.canAnswer = canAnswer
        do { try relay?.publish(state) } catch { endSession(failed: true, error: error) }
    }
    func showError(_ cause: Error = AppFailure.failed, catalog: Bool = false) {
        syncAccount()
        let failure = cause as? ChatGPTFailure
        feedback = failure
        let message =
            (catalog ? failure?.catalogMessage : failure?.message)
            ?? (catalog ? "Could not load ChatGPT models. Retry." : failureMessage)
        error = catalog ? "" : message
        catalogError = catalog ? message : ""
        state.error = message
        state.canAnswer = canAnswer
    }
    private func captureFailed(session: UUID) {
        guard sessionID == session else { return }
        captureFailure = session
        if state.live { endSession(failed: true) }
    }
    func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
    func openViewer() { if let link { NSWorkspace.shared.open(link) } }
    func shutdown() async {
        terminating = true
        settingsTask?.cancel()
        startTask?.cancel()
        await settingsTask?.value
        await startTask?.value
        await endSession().value
        await chatGPT.finishPendingRefresh()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var detailsExpanded = false
    let toggleIcon: () -> Void
    var maximumHeight: CGFloat?
    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
    private var answerIndex: Int {
        model.state.answers.firstIndex { $0.id == model.state.selectedID } ?? -1
    }
    private var feedbackMessages: [String] {
        [model.error, model.catalogError].filter { !$0.isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeader(
                status: model.status, working: model.working, live: model.state.live,
                answering: model.answering,
                canStart: model.canStartSession,
                error: model.error, catalogError: model.catalogError, feedback: model.feedback
            )
            .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .vertical) {
                settingsContent.fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    settingsContent
                }.scrollIndicators(.visible)
            }
            settingsFooter.fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: feedbackMessages, initial: true) { previous, messages in
            if previous != messages { detailsExpanded = false }
            guard !messages.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [
                    .announcement: messages.joined(separator: " "),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        .padding(26).frame(width: 520).frame(maxHeight: maximumHeight)
        // Size the AppKit window to the content after applying the screen height limit.
        .fixedSize(horizontal: true, vertical: true)
    }
    private var feedbackNotice: some View {
        let retry: (() -> Void)? =
            !model.catalogError.isEmpty && model.recovery == .usage
            ? { model.retryModels() } : nil
        return SettingsErrorNotice(
            messages: feedbackMessages,
            warning: model.feedback?.isWarning ?? false,
            diagnostic: model.feedback?.diagnostic ?? "",
            actionTitle: model.recoveryTitle, actionHint: model.recoveryHint,
            actionDisabled: !model.canRecover, action: model.recover,
            retryModels: retry, retryModelsDisabled: !model.canRetryModels,
            detailsExpanded: $detailsExpanded)
    }
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !feedbackMessages.isEmpty {
                feedbackNotice
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ChatGPT").font(.headline)
                if !model.account.isEmpty {
                    Text(model.activeAccountLabel).font(.subheadline).foregroundStyle(.secondary)
                } else if !model.savedAccounts.isEmpty {
                    Picker(
                        "Account",
                        selection: Binding(
                            get: { model.selectedAccountID }, set: model.selectAccount)
                    ) {
                        ForEach(model.savedAccounts, id: \.clientID) { saved in
                            Text(model.accountLabel(saved)).tag(saved.clientID)
                        }
                        Divider()
                        Text("Another account").tag("")
                    }.disabled(!model.canChooseAccount)
                }
                HStack(spacing: 12) {
                    Button(
                        model.account.isEmpty
                            ? model.savedAccounts.isEmpty ? "Sign in with ChatGPT" : "Sign in"
                            : "Sign out",
                        action: model.authenticate)
                    if model.needsPlanPermission {
                        Button("Enable ChatGPT plan usage", action: model.enablePlanUsage)
                    }
                }.disabled(!model.canAuthenticate)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker(
                        "Model",
                        selection: Binding(get: { model.modelSlug }, set: model.selectModel)
                    ) {
                        if model.models.isEmpty {
                            Text(model.modelPlaceholder).tag("")
                        }
                        ForEach(model.models) { Text($0.displayName).tag($0.slug) }
                    }.disabled(!model.canSelectModel)
                    Picker(
                        "Reasoning effort",
                        selection: Binding(get: { model.reasoningEffort }, set: model.selectEffort)
                    ) {
                        if model.selectedModel?.efforts.isEmpty ?? true {
                            Text(model.effortPlaceholder).tag("")
                        }
                        ForEach(model.selectedModel?.efforts ?? [], id: \.self) {
                            Text($0).tag($0)
                        }
                    }.disabled(!model.canSelectEffort)
                    Spacer(minLength: 0)
                }
                Picker("Microphone", selection: $model.microphone) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.disabled(model.working || model.state.live)
                Picker("Answer language", selection: $model.language) {
                    ForEach(AnswerLanguage.all, id: \.name) { Text($0.label).tag($0.name) }
                }.disabled(model.working || model.state.live)
                LabeledContent("Viewer endpoint") {
                    TextField("https://…", text: $model.relayURL).textFieldStyle(.roundedBorder)
                }.disabled(model.working || model.state.live)
            }
            if let link = model.link {
                HStack(spacing: 18) {
                    if let qr = qrCode(link.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(
                            width: 104, height: 104
                        ).padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.viewerStatus).font(.headline)
                        if !model.viewerDelivery.isEmpty {
                            Text(model.viewerDelivery).font(.subheadline).foregroundStyle(
                                .secondary)
                        }
                        Text("Keep this private session link to yourself.").font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open viewer", action: model.openViewer)
                            Button("Copy link", action: model.copyLink)
                        }
                    }
                }
            }
            SettingsControls(
                live: model.state.live, canAnswer: model.canAnswer,
                canGoBack: model.state.live && !model.working && answerIndex > 0,
                canGoForward: model.state.live && !model.working
                    && answerIndex < model.state.answers.count - 1,
                fontSize: model.state.fontSize, answer: model.answer, navigate: model.navigate,
                scroll: model.scroll, zoom: model.zoom)
        }
    }
    private var settingsFooter: some View {
        HStack {
            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .foregroundStyle(.red)
            menuBarIconButton
            Spacer()
            if model.state.live {
                sessionButton.buttonStyle(.bordered)
            } else {
                sessionButton.buttonStyle(.borderedProminent)
            }
        }
    }
    private var menuBarIconButton: some View {
        let title = model.iconVisible ? "Hide menu bar icon" : "Show menu bar icon"
        return Button(action: toggleIcon) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                ShortcutHint(key: .menuBarIcon, includeModifiers: true)
                    .opacity(0.75).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(ShortcutKey.menuBarIcon.hint)
    }
    private var sessionButton: some View {
        Button(model.state.live ? "Stop session" : "Start session") {
            if model.state.live { model.stopSession() } else { model.startSession() }
        }.disabled(model.working || (!model.state.live && !model.canStartSession))
    }
    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
            let cg = CIContext().createCGImage(
                image.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                from: image.extent.applying(CGAffineTransform(scaleX: 6, y: 6)))
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var shortcuts: [EventHotKeyRef] = []
    private var held: Set<UInt32> = []
    private var quitPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        model.iconVisible = item.isVisible
        if let symbol = NSImage(
            systemSymbolName: "tortoise.fill",
            accessibilityDescription: "Skill Issue"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)) {
            // The status button clips the tortoise's feet when given a symbol image directly.
            let image = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "Skill Issue"
            item.button?.image = image
        }
        item.button?.target = self
        item.button?.action = #selector(toggleSettings)
        let keys = [
            kVK_Space, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_ANSI_H,
            kVK_ANSI_Equal, kVK_ANSI_Minus,
        ]
        for (index, key) in keys.enumerated() {
            // The + key also works without Shift, like the other commands.
            for extra in key == kVK_ANSI_Equal ? [0, shiftKey] : [0] {
                var reference: EventHotKeyRef?
                let result = RegisterEventHotKey(
                    UInt32(key), UInt32(controlKey | optionKey | cmdKey | extra),
                    EventHotKeyID(signature: 0x534B_494C, id: UInt32(index + 1)),
                    GetApplicationEventTarget(), 0, &reference)
                if result == noErr, let reference {
                    shortcuts.append(reference)
                } else {
                    model.showError()
                }
            }
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        var events = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                        nil, &id) == noErr, id.signature == 0x534B_494C
                else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                Task { @MainActor in delegate.hotkey(id.id, released: released) }
                return noErr
            }, 2, &events, opaque, nil)
        if installed != noErr { model.showError() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        showSettings()
    }
    private func hotkey(_ id: UInt32, released: Bool) {
        if released {
            held.remove(id)
            return
        }
        if held.contains(id) && (id == 1 || id == 6) { return }
        held.insert(id)
        switch id {
        case 1: model.answer()
        case 2: model.scroll(-1)
        case 3: model.scroll(1)
        case 4: model.navigate(-1)
        case 5: model.navigate(1)
        case 6: toggleIcon()
        case 7: model.zoom(1)
        case 8: model.zoom(-1)
        default: break
        }
    }
    private func toggleIcon() {
        model.iconVisible.toggle()
        item.isVisible = model.iconVisible
    }
    @objc private func toggleSettings() {
        if let window, NSApp.isActive && window.isKeyWindow {
            window.close()
        } else {
            showSettings()
        }
    }
    private func showSettings() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    model: model, toggleIcon: { [weak self] in self?.toggleIcon() }))
            updateSettingsBounds()
            window.center()
        }
        updateSettingsBounds()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidChangeScreen(_ notification: Notification) { updateSettingsBounds() }
    func windowDidResize(_ notification: Notification) { updateSettingsBounds() }
    @objc private func screenParametersChanged(_ notification: Notification) {
        updateSettingsBounds()
    }
    private func updateSettingsBounds() {
        guard let window, let screen = window.screen ?? NSScreen.main,
            let host = window.contentView as? NSHostingView<SettingsView>
        else { return }
        let visible = screen.visibleFrame
        let height = window.contentRect(forFrameRect: visible).height
        if host.rootView.maximumHeight != height {
            host.rootView.maximumHeight = height
            host.layoutSubtreeIfNeeded()
        }
        let frame = window.frame
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if y != frame.minY { window.setFrameOrigin(NSPoint(x: frame.minX, y: y)) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        showSettings()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitPending else { return .terminateLater }
        showSettings()
        guard let window else { return .terminateCancel }
        quitPending = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Skill Issue?"
        alert.informativeText = "Any active session will stop. Session history is not saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertSecondButtonReturn else {
                quitPending = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            Task {
                await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main enum SkillIssue {
    // Application entry point called through @main.
    // swiftlint:disable:next unused_declaration
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
