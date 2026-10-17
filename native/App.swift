import AVFoundation
import AppKit
import Carbon
import Combine
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
    @Published private(set) var relayURL: String {
        didSet {
            guard relayURL != oldValue else { return }
            // Invalid drafts can contain pasted credentials or private session fragments.
            if let endpoint = viewerEndpoint { defaults.set(endpoint.origin, forKey: "relayURL") }
            if viewerAccessEnabled { restoreViewerCredentials() }
        }
    }
    @Published private(set) var viewerAccessEnabled: Bool
    @Published private(set) var viewerCredentials: ViewerAccessCredentials?
    @Published private(set) var viewerFailure: ViewerFailure?
    @Published var configuringViewerAccess = false
    @Published private(set) var shortcutModifiers: ShortcutModifiers
    @Published private(set) var shortcutError = ""
    private(set) var shortcutsSuspended = false
    @Published var configuringShortcuts = false
    @Published private(set) var microphone: String
    @Published private(set) var language: String
    @Published private(set) var answerSettings: AnswerSettings
    @Published var configuringAnswerSettings = false
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
    var working: Bool { terminating || operation != nil }
    var status: String {
        if terminating { return "Quitting…" }
        if let operation { return operation.label }
        if state.live { return answering ? "Thinking…" : "Listening" }
        if account.isEmpty { return "Signed out" }
        if chatGPT.requiresSignIn { return "Sign in required" }
        if needsPlanPermission { return "Permission required" }
        if viewerSetupRequired { return "Setup required" }
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
    private let viewerAccessStorage: ViewerAccessStorage
    private let shortcuts: ShortcutRegistry
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
    @Published private(set) var terminating = false
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
        !working && !state.live && chatGPT.accountsRestored
    }
    var canChooseAccount: Bool { canAuthenticate && account.isEmpty }
    var selectedModel: ChatGPTModel? { models.first { $0.slug == modelSlug } }
    var answering: Bool { state.answers.contains { $0.status == "generating" } }
    var canEditPreferences: Bool { !terminating }
    var canSelectModel: Bool { canEditPreferences && !loadingModels && !models.isEmpty }
    var canSelectEffort: Bool { canSelectModel && !(selectedModel?.efforts.isEmpty ?? true) }
    var canCancelOperation: Bool {
        guard !terminating else { return false }
        switch operation {
        case .signingIn?, .requestingPermission?, .preparingSpeech?, .starting?: return true
        default: return false
        }
    }
    var cancelOperationTitle: String {
        switch operation {
        case .preparingSpeech?, .starting?: return "Cancel startup"
        default: return "Cancel"
        }
    }
    func cancelOperation() {
        guard canCancelOperation else { return }
        switch operation {
        case .preparingSpeech?, .starting?: startTask?.cancel()
        case .signingIn?, .requestingPermission?: settingsTask?.cancel()
        default: break
        }
    }
    var canStartSession: Bool {
        guard !working, !state.live, canUseChatGPT,
            let model = selectedModel, !viewerSetupRequired
        else {
            return false
        }
        return model.supportsEffort(reasoningEffort)
    }
    var sessionUnavailableReason: String? {
        if working { return "Wait for the current step to finish." }
        if state.live || canStartSession { return nil }
        if !chatGPT.accountsRestored { return "Restore saved accounts first." }
        if account.isEmpty { return "Sign in with ChatGPT first." }
        if chatGPT.requiresSignIn { return "Sign in again first." }
        if !chatGPT.canUsePlan { return "Enable ChatGPT plan usage first." }
        if selectedModel == nil {
            return "Resolve the error above before starting a session."
        }
        if let viewerSetupIssue {
            return viewerSetupIssue == .invalidEndpoint
                ? "Enter a valid viewer endpoint first." : "Configure Cloudflare Access first."
        }
        return "Choose a supported reasoning effort first."
    }
    // Session resources stay fixed from startup until capture and relay have stopped.
    var lockReason: String? {
        if terminating { return "Wait for the app to quit." }
        if sessionTransition { return "Wait for the session transition to finish." }
        return state.live ? "Stop the session first." : nil
    }
    private var sessionTransition: Bool {
        switch operation {
        case .preparingSpeech?, .starting?, .stopping?: return true
        default: return false
        }
    }
    var canConfigureSession: Bool { canEditPreferences && !state.live && !sessionTransition }
    var canConfigureViewer: Bool { canConfigureSession }
    var canConfigureShortcuts: Bool { canEditPreferences }
    var viewerEndpoint: ViewerEndpoint? { try? ViewerEndpoint(relayURL) }
    var viewerSetupIssue: ViewerFailure? {
        guard let endpoint = viewerEndpoint else { return .invalidEndpoint }
        return viewerAccessEnabled && viewerCredentials?.origin != endpoint.origin
            ? .setupRequired : nil
    }
    var viewerSetupRequired: Bool { viewerSetupIssue != nil }
    var viewerSetupWarning: ViewerFailure? {
        error.isEmpty && catalogError.isEmpty ? viewerSetupIssue : nil
    }
    var viewerFailureStatus: String? {
        viewerFailure == .accessDenied ? "Viewer access denied" : nil
    }

    init(
        chatGPT: ChatGPT = ChatGPT(), defaults: UserDefaults = .standard,
        viewerAccessStorage: ViewerAccessStorage = .keychain,
        shortcuts: ShortcutRegistry = .disabled
    ) {
        self.chatGPT = chatGPT
        self.defaults = defaults
        self.viewerAccessStorage = viewerAccessStorage
        self.shortcuts = shortcuts
        let savedModifiers = ShortcutModifiers(
            rawValue: defaults.integer(forKey: "shortcutModifiers"))
        shortcutModifiers = savedModifiers.isValid ? savedModifiers : .standard
        viewerAccessEnabled = defaults.bool(forKey: "viewerAccessEnabled")
        relayURL = defaults.string(forKey: "relayURL") ?? "http://127.0.0.1:8787"
        microphone = defaults.string(forKey: "microphone") ?? ""
        language = defaults.string(forKey: "language") ?? "English"
        answerSettings = AnswerSettings(defaults: defaults)
        let savedFontSize = defaults.integer(forKey: "fontSize")
        if fontSizeRange.contains(savedFontSize) { state.fontSize = savedFontSize }
        state.modifiers = shortcutModifiers.symbols
        chatGPT.accountStateChanged = { [weak self] failure in
            guard let self else { return }
            self.syncAccount()
            if let failure { self.showError(failure) }
            self.publish()
        }
        if defaults.string(forKey: "relayURL") != nil {
            if let endpoint = viewerEndpoint {
                defaults.set(endpoint.origin, forKey: "relayURL")
            } else {
                defaults.removeObject(forKey: "relayURL")
            }
        }
        restoreAccounts()
        if viewerAccessEnabled { restoreViewerCredentials() }
    }
    func selectMicrophone(_ identifier: String) {
        guard canConfigureSession else { return }
        microphone = identifier
        defaults.set(identifier, forKey: "microphone")
    }
    func selectLanguage(_ selected: String) {
        guard canEditPreferences, AnswerLanguage.all.contains(where: { $0.name == selected }) else {
            return
        }
        language = selected
        defaults.set(selected, forKey: "language")
    }
    func setViewerEndpoint(_ endpoint: String) {
        guard canConfigureViewer else { return }
        relayURL = endpoint
    }
    func setViewerAccessEnabled(_ enabled: Bool) {
        guard canConfigureViewer else { return }
        viewerAccessEnabled = enabled
        defaults.set(enabled, forKey: "viewerAccessEnabled")
        if enabled {
            restoreViewerCredentials()
        } else if viewerFailure != nil {
            clearFeedback()
        }
    }
    private func restoreViewerCredentials() {
        guard let endpoint = viewerEndpoint else {
            viewerCredentials = nil
            return
        }
        do {
            let credentials = try viewerAccessStorage.load(endpoint.origin)
            try credentials?.validate(for: endpoint)
            viewerCredentials = credentials
            if viewerFailure == .credentialsUnavailable { clearFeedback() }
        } catch {
            viewerCredentials = nil
            showError(ViewerFailure.credentialsUnavailable)
        }
    }
    func configureViewerAccess() {
        guard canConfigureViewer, viewerAccessEnabled, viewerEndpoint != nil else { return }
        restoreViewerCredentials()
        configuringViewerAccess = true
    }
    func configureAnswerSettings() {
        guard canEditPreferences else { return }
        configuringAnswerSettings = true
    }
    func saveAnswerSettings(_ settings: AnswerSettings) {
        guard canEditPreferences else { return }
        settings.save(to: defaults)
        answerSettings = settings
        configuringAnswerSettings = false
    }
    func saveViewerAccess(_ credentials: ViewerAccessCredentials) throws {
        guard canConfigureViewer, viewerAccessEnabled,
            credentials.origin == viewerEndpoint?.origin
        else { throw ViewerFailure.setupRequired }
        guard let endpoint = viewerEndpoint else { throw ViewerFailure.invalidEndpoint }
        try credentials.validate(for: endpoint)
        try viewerAccessStorage.save(credentials)
        viewerCredentials = credentials
        if viewerFailure != nil { clearFeedback() }
        configuringViewerAccess = false
    }
    func registerShortcuts() {
        guard !shortcutsSuspended, !terminating else { return }
        do {
            try shortcuts.register(shortcutModifiers)
            if !shortcutError.isEmpty { shortcutError = "" }
        } catch {
            let message = (error as? AppFailure)?.message ?? failureMessage
            if shortcutError != message { shortcutError = message }
        }
    }
    func setShortcutsSuspended(_ suspended: Bool) {
        let suspended = suspended || terminating
        guard suspended != shortcutsSuspended else { return }
        shortcutsSuspended = suspended
        if suspended { shortcuts.unregister() } else { registerShortcuts() }
    }
    func configureShortcuts() {
        guard canConfigureShortcuts else { return }
        configuringShortcuts = true
    }
    func saveShortcutModifiers(_ modifiers: ShortcutModifiers) throws {
        guard canConfigureShortcuts, modifiers.isValid else { throw AppFailure.failed }
        try shortcuts.register(modifiers)
        if shortcutsSuspended { shortcuts.unregister() }
        shortcutModifiers = modifiers
        state.modifiers = modifiers.symbols
        defaults.set(modifiers.rawValue, forKey: "shortcutModifiers")
        shortcutError = ""
        configuringShortcuts = false
    }
    private func restoreAccounts() {
        guard !working, !state.live else { return }
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
        viewerFailure = nil
        state.error = ""
    }
    var recovery: ChatGPTFailure.Recovery {
        if chatGPT.requiresSignIn { return .signIn }
        let recovery = feedback?.recovery ?? (catalogError.isEmpty ? .none : .retry)
        if case .retry = recovery, !chatGPT.isSignedIn { return .signIn }
        return recovery
    }
    var recoveryTitle: String? {
        if let viewerFailure {
            if viewerFailure == .generic { return "Retry" }
            return viewerFailure == .invalidEndpoint
                ? nil
                : viewerAccessEnabled ? "Configure…" : "Enable Access"
        }
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
        !working && !state.live && canUseChatGPT
    }
    var canRecover: Bool {
        if let viewerFailure {
            return viewerFailure == .generic
                ? canStartSession
                : viewerFailure != .invalidEndpoint && canConfigureViewer && viewerEndpoint != nil
        }
        switch recovery {
        case .restore: return !working && !state.live
        case .save: return !working
        case .signIn, .enablePlan: return !working && !state.live
        case .usage, .settings: return true
        case .retry:
            return state.live ? canAnswer : canRetryModels
        case .configuration, .none: return false
        }
    }
    func recover() {
        guard canRecover else { return }
        if viewerFailure != nil {
            if viewerFailure == .generic {
                startSession()
                return
            }
            if !viewerAccessEnabled { setViewerAccessEnabled(true) }
            configureViewerAccess()
            return
        }
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
        state = ViewState(fontSize: state.fontSize, modifiers: state.modifiers)
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
                    url: relayURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    credentials: viewerAccessEnabled ? viewerCredentials : nil)
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
                relay.onFailure = { [weak self] error in
                    guard let self, self.sessionID == session else { return }
                    self.endSession(failed: true, error: error)
                }
                relay.onSelection = { [weak self] answerID, request in
                    guard let self, self.sessionID == session,
                        self.state.select(answerID: answerID, request: request)
                    else { return }
                    self.publish()
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
        if failed {
            state.live = false
            showError(error ?? AppFailure.failed)
        }
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
        let language = language
        let settings = answerSettings
        cancelAnswer()
        let id = UUID().uuidString
        let session = sessionID
        currentRequest = id
        state.beginAnswer(id: id, language: language)
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
                    input: input, language: language, model: model, effort: effort,
                    settings: settings
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
        guard !terminating, state.live else { return }
        state.select(direction)
        publish()
    }
    func scroll(_ direction: Int) {
        guard !terminating, state.live else { return }
        state.scroll(direction)
        publish()
    }
    func zoom(_ direction: Int) {
        guard canEditPreferences else { return }
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
        viewerFailure = cause as? ViewerFailure
        let message =
            viewerFailure?.message
            ?? (catalog
                ? failure?.catalogMessage : failure?.message ?? (cause as? AppFailure)?.message)
            ?? (catalog ? "Could not load ChatGPT models. Retry." : failureMessage)
        error = catalog ? "" : message
        catalogError = catalog ? message : ""
        state.error = message
        state.canAnswer = canAnswer
        if state.live && (failure?.stopsSession == true || viewerFailure?.stopsSession == true) {
            endSession()
        }
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
        setShortcutsSuspended(true)
        settingsTask?.cancel()
        startTask?.cancel()
        await settingsTask?.value
        await startTask?.value
        await endSession().value
        await chatGPT.finishPendingRefresh()
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    @State private var detailsExpanded = false
    let toggleIcon: () -> Void
    var showSystemPrompt: () -> Void = {}
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
        let messages = [model.error, model.catalogError].filter { !$0.isEmpty }
        if !messages.isEmpty { return messages }
        if !model.shortcutError.isEmpty { return [model.shortcutError] }
        return model.viewerSetupWarning.map { [$0.message] } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsHeader(
                status: model.status, working: model.working, live: model.state.live,
                answering: model.answering,
                canStart: model.canStartSession,
                error: model.error.isEmpty ? model.shortcutError : model.error,
                catalogError: model.catalogError, feedback: model.feedback,
                failureStatus: model.viewerFailureStatus,
                setupRequired: model.viewerSetupWarning != nil
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
        .padding(SettingsLayout.windowPadding).frame(width: 520).frame(maxHeight: maximumHeight)
        .disabled(model.terminating)
        .sheet(isPresented: $model.configuringViewerAccess) {
            ViewerAccessConfiguration(
                origin: model.viewerEndpoint?.origin ?? "",
                credentials: model.viewerCredentials, save: model.saveViewerAccess)
        }
        .sheet(isPresented: $model.configuringShortcuts) {
            ShortcutModifiersConfiguration(
                modifiers: model.shortcutModifiers, save: model.saveShortcutModifiers)
        }
        .sheet(isPresented: $model.configuringAnswerSettings) {
            AnswerSettingsConfiguration(
                settings: model.answerSettings, model: model.selectedModel,
                showSystemPrompt: showSystemPrompt,
                save: model.saveAnswerSettings)
        }
        // Size the AppKit window to the content after applying the screen height limit.
        .fixedSize(horizontal: true, vertical: true)
    }
    private var feedbackNotice: some View {
        if model.error.isEmpty && model.catalogError.isEmpty && !model.shortcutError.isEmpty {
            return SettingsNotice(
                messages: [model.shortcutError], warning: false, diagnostic: "",
                actionTitle: "Change…", actionDisabled: !model.canConfigureShortcuts,
                action: model.configureShortcuts, retryModels: nil, retryModelsDisabled: true,
                detailsExpanded: $detailsExpanded, disabledHelp: model.lockReason ?? "")
        }
        let retry: (() -> Void)? =
            !model.catalogError.isEmpty && model.recovery == .usage
            ? { model.retryModels() } : nil
        let setup = model.viewerSetupWarning
        let actionTitle: String?
        if let setup {
            actionTitle = setup == .setupRequired ? "Configure…" : nil
        } else {
            actionTitle = model.recoveryTitle
        }
        return SettingsNotice(
            messages: feedbackMessages,
            warning: setup != nil || model.feedback?.isWarning == true,
            diagnostic: setup == nil ? model.feedback?.diagnostic ?? "" : "",
            actionTitle: actionTitle,
            actionDisabled: setup != nil ? !model.canConfigureViewer : !model.canRecover,
            action: {
                if setup != nil { model.configureViewerAccess() } else { model.recover() }
            },
            retryModels: retry, retryModelsDisabled: !model.canRetryModels,
            detailsExpanded: $detailsExpanded, disabledHelp: model.lockReason ?? "")
    }
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            if !feedbackMessages.isEmpty {
                feedbackNotice
            }
            VStack(alignment: .leading, spacing: SettingsLayout.compactSpacing) {
                Text("ChatGPT").font(.headline)
                if !model.account.isEmpty {
                    Text(model.activeAccountLabel).font(.subheadline)
                        .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
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
                    }.disabled(!model.canChooseAccount).help(authenticationHelp)
                }
                HStack(spacing: SettingsLayout.spacing) {
                    Button(
                        model.account.isEmpty
                            ? model.savedAccounts.isEmpty ? "Sign in with ChatGPT" : "Sign in"
                            : "Sign out",
                        action: model.authenticate)
                    if model.needsPlanPermission {
                        Button("Enable ChatGPT plan usage", action: model.enablePlanUsage)
                    }
                }.disabled(!model.canAuthenticate).help(authenticationHelp)
            }
            VStack(alignment: .leading, spacing: SettingsLayout.spacing) {
                HStack(spacing: SettingsLayout.spacing) {
                    Picker(
                        "Model",
                        selection: Binding(get: { model.modelSlug }, set: model.selectModel)
                    ) {
                        if model.models.isEmpty {
                            Text(model.modelPlaceholder).tag("")
                        }
                        ForEach(model.models) { Text($0.displayName).tag($0.slug) }
                    }.disabled(!model.canSelectModel).help(modelHelp)
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
                    }.disabled(!model.canSelectEffort).help(modelHelp)
                    Spacer(minLength: 0)
                }
                Picker(
                    "Answer language",
                    selection: Binding(get: { model.language }, set: model.selectLanguage)
                ) {
                    ForEach(AnswerLanguage.all, id: \.name) { Text($0.label).tag($0.name) }
                }
                Button("Answer settings…", action: model.configureAnswerSettings)
                Text("Changes apply to the next answer request.")
                    .font(.callout).foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                    .padding(.bottom, SettingsLayout.compactSpacing)
                Picker(
                    "Microphone",
                    selection: Binding(get: { model.microphone }, set: model.selectMicrophone)
                ) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.disabled(!model.canConfigureSession).help(model.lockReason ?? "")
                LabeledContent("Viewer endpoint") {
                    HStack(spacing: SettingsLayout.spacing) {
                        TextField(
                            "https://…",
                            text: Binding(get: { model.relayURL }, set: model.setViewerEndpoint)
                        ).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Viewer endpoint")
                            .disabled(!model.canConfigureViewer).help(model.lockReason ?? "")
                        SettingsLink(title: "Viewer setup", destination: AppBuild.viewerSetupURL)
                            .fixedSize()
                    }
                }
                HStack(spacing: SettingsLayout.spacing) {
                    Toggle(
                        "Use Cloudflare Access",
                        isOn: Binding(
                            get: { model.viewerAccessEnabled }, set: model.setViewerAccessEnabled)
                    ).toggleStyle(.switch).fixedSize()
                    if model.viewerAccessEnabled {
                        Button("Configure…", action: model.configureViewerAccess)
                            .disabled(model.viewerEndpoint == nil)
                            .help(
                                model.viewerEndpoint == nil
                                    ? "Enter a valid viewer endpoint first."
                                    : model.lockReason ?? "")
                    }
                    Spacer(minLength: 0)
                }.disabled(!model.canConfigureViewer).help(model.lockReason ?? "")
            }
            if let link = model.link {
                HStack(spacing: 18) {
                    if let qr = qrCode(link.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(
                            width: 104, height: 104
                        ).padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Private viewer QR code")
                    }
                    VStack(alignment: .leading, spacing: SettingsLayout.compactSpacing) {
                        Text(model.viewerStatus).font(.headline)
                        if !model.viewerDelivery.isEmpty {
                            Text(model.viewerDelivery).font(.subheadline)
                                .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                        }
                        Text("Keep this private session link to yourself.").font(.caption)
                            .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
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
                fontSize: model.state.fontSize, canChangeTextSize: model.canEditPreferences,
                modifiers: model.shortcutModifiers,
                canChangeModifiers: model.canConfigureShortcuts,
                changeModifiersHelp:
                    "Change the shortcut modifiers without restarting the session.",
                answer: model.answer,
                navigate: model.navigate, scroll: model.scroll, zoom: model.zoom,
                changeModifiers: model.configureShortcuts)
        }
    }
    private var authenticationHelp: String {
        if model.canAuthenticate { return "" }
        if model.working { return "Wait for the current step to finish." }
        return model.lockReason ?? "Restore saved accounts first."
    }
    private var modelHelp: String {
        model.loadingModels ? "Wait for available models to load." : ""
    }
    private var settingsFooter: some View {
        HStack {
            Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                .foregroundStyle(.red)
            menuBarIconButton
            Spacer()
            if model.canCancelOperation {
                Button(model.cancelOperationTitle, action: model.cancelOperation)
            } else if model.state.live {
                sessionButton.buttonStyle(.bordered)
            } else {
                sessionButton.buttonStyle(.borderedProminent)
            }
        }
    }
    private var menuBarIconButton: some View {
        let title = model.iconVisible ? "Hide menu bar icon" : "Show menu bar icon"
        return Button(action: toggleIcon) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsLayout.spacing) {
                Text(title)
                ShortcutHint(key: .menuBarIcon, modifiers: model.shortcutModifiers)
                    .opacity(0.75).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(ShortcutKey.menuBarIcon.hint(model.shortcutModifiers))
    }
    private var sessionButton: some View {
        Button(model.state.live ? "Stop session" : "Start session") {
            if model.state.live { model.stopSession() } else { model.startSession() }
        }.disabled(model.working || (!model.state.live && !model.canStartSession))
            .help(model.sessionUnavailableReason ?? "")
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
    let model = Model(shortcuts: .carbon())
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var systemPromptWindow: SystemPromptWindow?
    private var settingsObservation: AnyCancellable?
    private var configurationOpen = false
    private var held: Set<ShortcutKey> = []
    private var heldModifiers = ShortcutModifiers.standard
    private var quitPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = applicationMenu()
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
        model.registerShortcuts()
        settingsObservation = model.$configuringViewerAccess
            .combineLatest(model.$configuringShortcuts, model.$configuringAnswerSettings)
            .sink { [weak self] access, shortcuts, answer in
                self?.configurationOpen = access || shortcuts || answer
                self?.updateShortcuts()
            }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateShortcuts), name: name, object: nil)
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
                        nil, &id) == noErr, id.signature == hotKeySignature
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
        guard globalShortcutKeys.indices.contains(Int(id) - 1) else { return }
        if heldModifiers != model.shortcutModifiers || model.shortcutsSuspended {
            held.removeAll()
            heldModifiers = model.shortcutModifiers
        }
        let key = globalShortcutKeys[Int(id) - 1]
        if released {
            held.remove(key)
            return
        }
        guard !model.shortcutsSuspended, !model.terminating, !quitPending else { return }
        if held.contains(key) && (key == .space || key == .menuBarIcon) { return }
        held.insert(key)
        switch key {
        case .space: model.answer()
        case .up: model.scroll(-1)
        case .down: model.scroll(1)
        case .left: model.navigate(-1)
        case .right: model.navigate(1)
        case .menuBarIcon: toggleIcon()
        case .plus: model.zoom(1)
        case .minus: model.zoom(-1)
        }
    }
    private func toggleIcon() {
        guard model.canEditPreferences else { return }
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
            let window = ApplicationWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.focusChanged = { [weak self] in self?.updateShortcuts() }
            self.window = window
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    model: model, toggleIcon: { [weak self] in self?.toggleIcon() },
                    showSystemPrompt: { [weak self] in self?.showSystemPrompt() }))
            updateSettingsBounds()
            window.center()
        }
        updateSettingsBounds()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func showSystemPrompt() {
        do {
            if systemPromptWindow == nil {
                let controller = SystemPromptWindow(prompt: try SystemPrompt.load())
                (controller.window as? ApplicationWindow)?.focusChanged = { [weak self] in
                    self?.updateShortcuts()
                }
                systemPromptWindow = controller
            }
            systemPromptWindow?.show()
        } catch { model.showError(error) }
    }
    @objc private func updateShortcuts() {
        let keyWindow = NSApp.keyWindow
        let editing =
            NSApp.isActive
            && (configurationOpen || keyWindow?.sheetParent != nil
                || keyWindow?.firstResponder is NSTextView)
        let suspended = editing || quitPending || model.terminating
        if suspended != model.shortcutsSuspended {
            held.removeAll()
            heldModifiers = model.shortcutModifiers
            model.setShortcutsSuspended(suspended)
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { updateShortcuts() }
    func applicationDidResignActive(_ notification: Notification) { updateShortcuts() }
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
        updateShortcuts()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Skill Issue?"
        alert.informativeText = "Any active session will stop. Session history is not saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertSecondButtonReturn else {
                quitPending = false
                updateShortcuts()
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
        #if PROMPT_EVAL
            PromptEvaluation.run()
        #elseif README_SCREENSHOTS
            ReadmeScreenshots.run()
        #else
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        #endif
    }
}
