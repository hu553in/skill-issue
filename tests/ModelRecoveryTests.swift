import Foundation
import Testing

@testable import SkillIssue

private final class RecoveryAccountStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTAccounts?
    private var failLoad = false
    private var failSave = false
    private var writes = 0
    init(session: ChatGPTSession?) {
        value = ChatGPTAccounts(
            account: ChatGPTAccount(
                clientID: "test-client", subject: "test-subject", email: "test@example.invalid",
                session: session))
    }
    init(accounts: ChatGPTAccounts) { value = accounts }
    func rejectNextLoad() { lock.withLock { failLoad = true } }
    func rejectSaves(_ reject: Bool) { lock.withLock { failSave = reject } }
    var writeCount: Int { lock.withLock { writes } }
    var current: ChatGPTAccount? { lock.withLock { value?.selected } }
    var storage: AccountStorage {
        AccountStorage(
            load: { [self] in
                try lock.withLock {
                    if failLoad {
                        failLoad = false
                        throw AppFailure.failed
                    }
                    return value
                }
            },
            save: { [self] account in
                try lock.withLock {
                    if failSave { throw AppFailure.failed }
                    value = account
                    writes += 1
                }
            })
    }
}

private final class RecoveryViewerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ViewerAccessCredentials] = [:]
    private var reads: [String] = []
    private var writes: [ViewerAccessCredentials] = []
    private var failLoad = false
    private var failSave = false
    var loadedOrigins: [String] { lock.withLock { reads } }
    var savedCredentials: [ViewerAccessCredentials] { lock.withLock { writes } }
    func record(for origin: String) -> ViewerAccessCredentials? { lock.withLock { values[origin] } }
    func inject(_ value: ViewerAccessCredentials, for origin: String) {
        lock.withLock { values[origin] = value }
    }
    func rejectLoads(_ reject: Bool) { lock.withLock { failLoad = reject } }
    func rejectSaves(_ reject: Bool) { lock.withLock { failSave = reject } }
    var storage: ViewerAccessStorage {
        ViewerAccessStorage(
            load: { [self] origin in
                try lock.withLock {
                    reads.append(origin)
                    if failLoad { throw AppFailure.failed }
                    return values[origin]
                }
            },
            save: { [self] value in
                try lock.withLock {
                    if failSave { throw ViewerFailure.credentialsNotSaved }
                    values[value.origin] = value
                    writes.append(value)
                }
            })
    }
}

private final class RecoveryHTTP: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let refresh = url.path == "/api/accounts/oauth/token"
        let scenario = request.value(forHTTPHeaderField: "X-Recovery-Test")!
        let code = refresh ? "invalid_grant" : scenario
        let catalog = !refresh && ["models", "models-rotating"].contains(code)
        let firstRefresh: Bool
        do {
            if refresh && scenario == "models-rotating" {
                firstRefresh = String(decoding: try requestBody(request), as: UTF8.self)
                    .contains("refresh_token=test-refresh")
            } else {
                firstRefresh = false
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let body =
            firstRefresh
            ? "{\"access_token\":\"rotated-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":30,\"scope\":\"chatgpt.tokens.use.direct\",\"token_type\":\"bearer\"}"
            : catalog
                ? "{\"models\":[{\"slug\":\"gpt-6-luna\",\"display_name\":\"GPT-6 Luna\",\"visibility\":\"list\",\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}]},{\"slug\":\"gpt-6-sol\",\"display_name\":\"GPT-6 Sol\",\"visibility\":\"list\",\"supported_reasoning_levels\":[{\"effort\":\"low\"}]}]}"
                : refresh ? "{\"error\":\"\(code)\"}" : "{\"error\":{\"code\":\"\(code)\"}}"
        let response = HTTPURLResponse(
            url: url, statusCode: catalog || firstRefresh ? 200 : refresh ? 400 : 503,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "x-request-id": "test-request"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class RecoveryShortcuts {
    var registered: [ShortcutModifiers] = []
    var unregistered = 0
    var taken: ShortcutModifiers?
    var active: ShortcutModifiers?
    var registry: ShortcutRegistry {
        ShortcutRegistry(
            register: { [self] modifiers in
                if modifiers == taken {
                    throw AppFailure.shortcutUnavailable("\(modifiers.symbols) + Space")
                }
                registered.append(modifiers)
                active = modifiers
            },
            unregister: { [self] in
                unregistered += 1
                active = nil
            })
    }
}

@MainActor
struct ModelRecoveryTests {
    private func configuredModel(
        session: URLSession, storage: AccountStorage, defaults: TestDefaults = TestDefaults(),
        viewerAccessStorage: ViewerAccessStorage = .keychain,
        shortcuts: ShortcutRegistry = .disabled
    ) -> Model {
        return Model(
            chatGPT: ChatGPT(
                session: session, storage: storage, defaults: defaults,
                openAuthorization: { _ in false }),
            defaults: defaults, viewerAccessStorage: viewerAccessStorage, shortcuts: shortcuts)
    }
    private func session(code: String = "subscription_sharing_usage_unavailable") -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryHTTP.self]
        configuration.httpAdditionalHeaders = ["X-Recovery-Test": code]
        return URLSession(configuration: configuration)
    }
    private func tokens(expired: Bool = false, plan: Bool = true) -> ChatGPTSession {
        ChatGPTSession(
            idToken: "test-id", accessToken: "test-access", refreshToken: "test-refresh",
            expires: expired ? .distantPast : Date().addingTimeInterval(3600),
            scopes: plan ? ["chatgpt.tokens.use.direct"] : ["openid", "profile", "email"])
    }
    private func loaded(_ model: Model, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.working, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.working, sourceLocation: sourceLocation)
    }

    @Test func failedAccountReadBlocksSignInUntilExplicitRestore() async throws {
        let first = ChatGPTAccount(
            clientID: "first", subject: "one", email: "one@example.invalid", session: nil)
        var bank = ChatGPTAccounts(account: first)
        bank.accounts.append(
            ChatGPTAccount(
                clientID: "second", subject: "two", email: "two@example.invalid", session: nil))
        let store = RecoveryAccountStore(accounts: bank)
        store.rejectNextLoad()
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: store.storage)
        #expect(model.working && model.status == "Restoring accounts…")
        #expect(model.modelPlaceholder == "Restoring accounts…")
        try await loaded(model)
        #expect(!model.canAuthenticate && !model.canChooseAccount)
        #expect(model.recovery == .restore && model.canRecover)
        #expect(model.sessionUnavailableReason == "Restore saved accounts first.")
        #expect(model.modelPlaceholder == "Unavailable")
        model.authenticate()
        model.selectAccount("first")
        model.selectAccount("")
        #expect(!model.working && store.writeCount == 0)
        model.recover()
        #expect(model.working && model.modelPlaceholder == "Restoring accounts…")
        try await loaded(model)
        #expect(model.canAuthenticate && model.canChooseAccount)
        #expect(model.savedAccounts.map(\.clientID) == ["first", "second"])
        #expect(model.error.isEmpty && store.writeCount == 0)
        await model.shutdown()
    }

    @Test func identityOnlySignInKeepsAccountAndOffersPlanPermission() async throws {
        let stored = RecoveryAccountStore(session: tokens(plan: false))
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.account == "test@example.invalid")
        #expect(model.needsPlanPermission && !model.canStartSession && model.models.isEmpty)
        #expect(model.catalogError.isEmpty)
        #expect(model.recovery == .enablePlan && model.canRecover)
        #expect(model.status == "Permission required" && model.feedback?.isWarning == true)
        model.state.live = true
        #expect(!model.canAnswer && !model.canRecover)
        model.showError(ChatGPTFailure.planDisabled)
        #expect(!model.state.live && model.working)
        try await loaded(model)
        #expect(model.canRecover && model.canAuthenticate && model.needsPlanPermission)
        await model.shutdown()
    }

    @Test func signedOutRegistrationDoesNotLookConnected() async throws {
        let stored = RecoveryAccountStore(session: nil)
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.account.isEmpty && model.models.isEmpty)
        #expect(!model.canStartSession && !model.needsPlanPermission)
        #expect(model.error.isEmpty && model.catalogError.isEmpty)
        #expect(stored.current?.clientID == "test-client")
        #expect(model.status == "Signed out")
        #expect(model.sessionUnavailableReason == "Sign in with ChatGPT first.")
        model.authenticate()
        #expect(model.working && model.status == "Signing in…" && !model.canStartSession)
        try await loaded(model)
        await model.shutdown()
    }

    @Test func consentWaitAndFailureKeepTheirActualReadiness() async throws {
        let stored = RecoveryAccountStore(session: tokens(plan: false))
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.enablePlanUsage()
        #expect(model.working && model.status == "Waiting for permission…")
        #expect(!model.canStartSession && model.effortPlaceholder == "Not available")
        try await loaded(model)
        #expect(!model.canStartSession && model.status == "Permission required")
        #expect(!model.error.isEmpty)
        await model.shutdown()
    }

    @Test func terminalRefreshUpdatesAccountAndPreservesRegistration() async throws {
        let stored = RecoveryAccountStore(session: tokens(expired: true))
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.account.isEmpty && model.models.isEmpty && !model.canStartSession)
        #expect(model.recovery == .signIn && model.canRecover)
        #expect(stored.current?.session == nil && stored.current?.subject == "test-subject")
        #expect(model.feedback?.requestID == "test-request")
        await model.shutdown()
    }

    @Test func temporaryCatalogFailureKeepsSessionAndOffersRetry() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.account == "test@example.invalid" && stored.current?.session != nil)
        #expect(!model.catalogError.isEmpty && !model.canStartSession)
        #expect(model.recovery == .retry && model.canRecover)
        #expect(model.feedback?.code == "subscription_sharing_usage_unavailable")
        #expect(model.status == "Unavailable")
        await model.shutdown()
    }

    @Test func catalogUsageLimitOffersUsageAndManualReload() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "subscription_sharing_usage_limit_exceeded")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.recovery == .usage && model.recoveryTitle == "View usage")
        #expect(model.canRetryModels && model.catalogError.contains("then choose Retry"))
        #expect(model.account == "test@example.invalid" && stored.current?.session != nil)
        #expect(model.feedback?.status == 503 && model.feedback?.requestID == "test-request")
        model.state.live = true
        #expect(model.canRecover)
        await model.shutdown()
    }

    @Test(arguments: [
        "subscription_sharing_usage_limit_exceeded",
        "subscription_sharing_unsupported_capability",
    ])
    func manualRetryKeepsLiveAnswersWithoutAutomaticReplay(_ code: String) async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "saved-answer", language: "English")
        model.state.answers[0].text = "A useful existing answer"
        model.state.answers[0].status = "complete"
        #expect(model.status == "Listening")
        let command = model.state.command
        let body = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
        model.showError(ChatGPTFailure(status: 200, body: body))
        #expect(model.canAnswer && model.state.canAnswer && model.state.live)
        #expect(model.catalogError.isEmpty && !model.canRetryModels)
        await Task.yield()
        #expect(model.state.command == command && model.state.answers.count == 1)
        #expect(model.state.answers[0].text == "A useful existing answer")
        #expect(model.state.answers[0].status == "complete")
        #expect(model.account == "test@example.invalid" && stored.current?.session != nil)
        await model.shutdown()
    }

    @Test func transientLiveFailureOffersExplicitNewAnswerWithoutReplay() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "saved-answer", language: "English")
        model.state.answers[0].text = "Partial answer"
        let body = Data("{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}".utf8)
        model.showError(ChatGPTFailure(status: 503, body: body))
        #expect(model.canAnswer && model.canRecover && model.recoveryTitle == "Request answer")
        await Task.yield()
        #expect(model.state.live && model.state.answers.count == 1)
        #expect(model.state.answers[0].text == "Partial answer")
        await model.shutdown()
    }

    @Test func livePreferencesCanChangeWithoutChangingGeneratingOrOlderAnswers() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "existing", language: "English")
        model.state.answers[0].text = "An existing answer"
        model.state.answers[0].status = "complete"
        let selection = model.state.selection
        #expect(model.canSelectModel && model.canSelectEffort)
        model.selectEffort("high")
        #expect(model.reasoningEffort == "high")
        model.selectModel("gpt-6-sol")
        #expect(model.modelSlug == "gpt-6-sol" && model.reasoningEffort == "low")
        #expect(model.state.live && model.state.selection == selection)
        #expect(model.state.answers[0].text == "An existing answer")
        model.state.beginAnswer(id: "generating", language: "English")
        model.state.select(-1)
        #expect(model.state.selectedID == "existing" && model.status == "Thinking…")
        let retained = model.state
        #expect(model.canSelectModel && model.canSelectEffort)
        model.selectModel("gpt-6-luna")
        model.selectEffort("high")
        model.selectLanguage("Russian")
        model.saveAnswerSettings(AnswerSettings(verbosity: .low, codingLanguage: "Python"))
        #expect(model.modelSlug == "gpt-6-luna" && model.reasoningEffort == "high")
        #expect(model.language == "Russian" && model.answerSettings.codingLanguage == "Python")
        #expect(model.state == retained)
        model.state.answers[1].status = "failed"
        #expect(model.canSelectModel)
        #expect(model.status == "Listening")
        await model.shutdown()
    }

    @Test func localPreferencesPersistWithoutStartingAndSessionResourcesStayFixed() async throws {
        let defaults = TestDefaults()
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage, defaults: defaults)
        #expect(model.working && model.canConfigureSession && model.canEditPreferences)
        model.selectMicrophone("test-microphone")
        model.selectLanguage("Russian")
        model.zoom(1)
        #expect(defaults.string(forKey: "microphone") == "test-microphone")
        #expect(defaults.string(forKey: "language") == "Russian")
        #expect(defaults.integer(forKey: "fontSize") == 22)
        try await loaded(model)
        let endpoint = model.relayURL
        model.state.live = true
        model.selectMicrophone("replacement")
        model.setViewerEndpoint("https://replacement.example.invalid")
        #expect(model.microphone == "test-microphone" && model.relayURL == endpoint)
        #expect(defaults.string(forKey: "microphone") == "test-microphone")
        await model.shutdown()
        let retained = model.state
        model.selectLanguage("English")
        model.selectMicrophone("replacement")
        model.setViewerEndpoint("https://replacement.example.invalid")
        model.saveAnswerSettings(AnswerSettings(customInstructions: "Must not save while quitting"))
        model.configureAnswerSettings()
        model.zoom(1)
        #expect(!model.canEditPreferences && !model.canConfigureSession)
        #expect(model.language == "Russian" && model.answerSettings == AnswerSettings())
        #expect(!model.configuringAnswerSettings && model.state == retained)
        let restored = configuredModel(session: http, storage: stored.storage, defaults: defaults)
        try await loaded(restored)
        #expect(restored.microphone == "test-microphone" && restored.language == "Russian")
        #expect(restored.state.fontSize == 22)
        await restored.shutdown()
    }

    @Test func editingSuspendsRegistrationsAndReportsAConflictWhenResuming() async throws {
        let shortcuts = RecoveryShortcuts()
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            shortcuts: shortcuts.registry)
        try await loaded(model)
        model.state.live = true
        model.registerShortcuts()
        #expect(shortcuts.active == .standard)
        model.setShortcutsSuspended(true)
        model.setShortcutsSuspended(true)
        #expect(model.shortcutsSuspended && shortcuts.active == nil && shortcuts.unregistered == 1)
        try model.saveShortcutModifiers([.control, .shift])
        #expect(shortcuts.active == nil && model.shortcutModifiers == [.control, .shift])
        shortcuts.taken = [.control, .shift]
        model.setShortcutsSuspended(false)
        #expect(shortcuts.active == nil && !model.shortcutError.isEmpty)
        model.setShortcutsSuspended(true)
        shortcuts.taken = nil
        model.setShortcutsSuspended(false)
        #expect(shortcuts.active == [.control, .shift] && model.shortcutError.isEmpty)
        await model.shutdown()
        model.setShortcutsSuspended(false)
        #expect(shortcuts.active == nil && model.shortcutsSuspended)
    }

    @Test func startupCanBeCancelledBeforeAnyCapturePreparation() async throws {
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage)
        try await loaded(model)
        try #require(model.canStartSession)
        model.startSession()
        #expect(model.working && !model.canConfigureSession && model.canCancelOperation)
        #expect(model.cancelOperationTitle == "Cancel startup" && model.canSelectModel)
        model.selectLanguage("Russian")
        // Cancel before yielding: no capture or speech preparation can have started.
        model.cancelOperation()
        try await loaded(model)
        #expect(!model.state.live && model.canConfigureSession && !model.canCancelOperation)
        #expect(model.error.isEmpty && model.language == "Russian")
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func browserAuthorizationCanBeCancelledWithoutChangingSavedAccount(consent: Bool) async throws {
        let stored = RecoveryAccountStore(session: consent ? tokens(plan: false) : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(stored.current)
        let defaults = TestDefaults()
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        var opened = false
        let model = Model(
            chatGPT: ChatGPT(
                session: http, storage: stored.storage, defaults: defaults,
                openAuthorization: { _ in
                    opened = true
                    return true
                }), defaults: defaults)
        try await loaded(model)
        if consent { model.enablePlanUsage() } else { model.authenticate() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !opened && model.working && ContinuousClock.now < deadline { await Task.yield() }
        try #require(opened && model.canCancelOperation && model.working)
        #expect(model.canConfigureSession && model.canEditPreferences && !model.canAuthenticate)
        model.cancelOperation()
        try await loaded(model)
        #expect(model.error.isEmpty && stored.writeCount == 0)
        #expect(try encoder.encode(stored.current) == original)
        #expect(!model.canCancelOperation && model.canAuthenticate)
        await model.shutdown()
    }

    @Test func unconfirmedSignOutShowsWarningAndSettingsAction() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.authenticate()
        #expect(model.working && model.status == "Signing out…")
        try await loaded(model)
        #expect(model.account.isEmpty && stored.current?.session == nil)
        #expect(model.feedback?.isWarning == true && !model.error.isEmpty)
        #expect(model.recovery == .settings && model.canRecover)
        #expect(stored.current?.clientID == "test-client")
        await model.shutdown()
    }

    @Test func savedAccountSelectionKeepsDistinctLabelsAndRegistration() async throws {
        let first = ChatGPTAccount(
            clientID: "first-client", subject: "same-subject", email: "same@example.invalid",
            session: nil)
        let second = ChatGPTAccount(
            clientID: "second-client", subject: "same-subject", email: "same@example.invalid",
            session: nil)
        var accounts = ChatGPTAccounts(account: first)
        accounts.accounts.append(second)
        let stored = RecoveryAccountStore(accounts: accounts)
        let http = session()
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        #expect(model.savedAccounts.count == 2 && model.canChooseAccount)
        #expect(model.accountLabel(first) == "same@example.invalid · Account 1")
        #expect(model.accountLabel(second) == "same@example.invalid · Account 2")
        model.selectAccount("second-client")
        #expect(
            model.selectedAccountID == "second-client"
                && stored.current?.clientID == "second-client")
        #expect(model.savedAccounts.count == 2 && model.account.isEmpty && model.models.isEmpty)
        model.selectAccount("")
        #expect(model.selectedAccountID.isEmpty && stored.current == nil)
        #expect(model.savedAccounts.count == 2 && !model.working)
        model.selectAccount("unknown-client")
        #expect(model.selectedAccountID.isEmpty && stored.current == nil)
        #expect(!model.error.isEmpty && model.savedAccounts.count == 2)
        model.selectAccount("second-client")
        #expect(model.selectedAccountID == "second-client" && model.error.isEmpty)
        model.state.live = true
        model.selectAccount("first-client")
        model.selectAccount("")
        #expect(model.selectedAccountID == "second-client")
        await model.shutdown()
    }

    @Test(arguments: ["microphone", "screen"])
    func missingCapturePermissionsExplainTheSystemSettingWithoutAccountRecovery(
        _ permission: String
    )
        async throws
    {
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage)
        try await loaded(model)
        model.showError(
            permission == "microphone" ? AppFailure.microphonePermission : .screenCapturePermission)
        #expect(model.error.contains("System Settings > Privacy & Security"))
        #expect(
            model.error.contains(
                permission == "microphone" ? "Microphone" : "Screen & System Audio Recording"))
        #expect(model.error.contains("start the session again"))
        #expect(model.state.error == model.error && !model.state.live)
        #expect(model.feedback == nil && model.viewerFailure == nil)
        #expect(model.recoveryTitle == nil && !model.canRecover && model.canStartSession)
        #expect(model.models.count == 2 && model.account == "test@example.invalid")
        await model.shutdown()
    }

    @Test func viewerEndpointDraftsNeverPersistCredentialsOrPrivateFragments() async throws {
        let defaults = TestDefaults()
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults)
        try await loaded(model)
        model.setViewerEndpoint(" HTTPS://VIEWER.EXAMPLE.INVALID:443/ ")
        #expect(defaults.string(forKey: "relayURL") == "https://viewer.example.invalid")
        for draft in [
            "https://user:secret@viewer.example.invalid",
            "https://viewer.example.invalid?token=secret",
            "https://viewer.example.invalid#private-session-key",
            "https://viewer.example.invalid/path",
            "",
        ] {
            model.setViewerEndpoint(draft)
            #expect(model.relayURL == draft && model.viewerSetupWarning == .invalidEndpoint)
            #expect(!model.canStartSession && model.viewerEndpoint == nil)
            #expect(defaults.string(forKey: "relayURL") == "https://viewer.example.invalid")
        }
        model.setViewerEndpoint("https://other.example.invalid/")
        #expect(defaults.string(forKey: "relayURL") == "https://other.example.invalid")
        #expect(model.canStartSession && model.viewerSetupWarning == nil)
        await model.shutdown()
    }

    @Test func unsafePreviouslySavedEndpointIsRemovedWithoutHidingItsWarning() async throws {
        let defaults = TestDefaults()
        let unsafe = "https://user:secret@viewer.example.invalid?token=secret#private-key"
        defaults.set(unsafe, forKey: "relayURL")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let client = ChatGPT(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await loaded(model)
        #expect(model.relayURL == unsafe && model.viewerSetupWarning == .invalidEndpoint)
        #expect(defaults.string(forKey: "relayURL") == nil && !model.canStartSession)
        await model.shutdown()
    }

    @Test func accessIsOptionalAndEmptyEnabledAccessBlocksStartup() async throws {
        let store = RecoveryViewerStore()
        store.rejectLoads(true)
        let defaults = TestDefaults()
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(!model.viewerAccessEnabled && !model.viewerSetupRequired)
        #expect(model.viewerSetupIssue == nil && model.viewerSetupWarning == nil)
        #expect(model.canStartSession && model.status == "Ready")
        #expect(model.sessionUnavailableReason == nil && model.lockReason == nil)
        #expect(store.loadedOrigins.isEmpty && store.savedCredentials.isEmpty)
        model.configureViewerAccess()
        #expect(!model.configuringViewerAccess && store.loadedOrigins.isEmpty)
        store.rejectLoads(false)
        model.setViewerAccessEnabled(true)
        #expect(model.viewerAccessEnabled && defaults.bool(forKey: "viewerAccessEnabled"))
        #expect(model.viewerSetupRequired && model.status == "Setup required")
        #expect(
            model.viewerSetupIssue == .setupRequired && model.viewerSetupWarning == .setupRequired)
        #expect(model.error.isEmpty && model.catalogError.isEmpty && model.feedback == nil)
        #expect(!model.canStartSession && model.viewerCredentials == nil)
        #expect(model.sessionUnavailableReason == "Configure Cloudflare Access first.")
        model.startSession()
        #expect(!model.working && !model.state.live)
        model.setViewerAccessEnabled(false)
        #expect(!model.viewerSetupRequired && model.canStartSession && model.status == "Ready")
        #expect(model.viewerSetupWarning == nil && model.viewerSetupIssue == nil)
        #expect(store.savedCredentials.isEmpty)
        model.showError(ViewerFailure.generic)
        #expect(model.recoveryTitle == "Retry" && model.canRecover)
        #expect(model.canStartSession && !model.state.live)
        await model.shutdown()
    }

    @Test func shortcutModifiersSaveAtomicallyAndReachTheViewer() async throws {
        let shortcuts = RecoveryShortcuts()
        let defaults = TestDefaults()
        defaults.set(ShortcutModifiers.command.rawValue, forKey: "shortcutModifiers")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let accountStore = RecoveryAccountStore(session: tokens())
        let model = configuredModel(
            session: http, storage: accountStore.storage, defaults: defaults,
            shortcuts: shortcuts.registry)
        try await loaded(model)
        #expect(model.shortcutModifiers == .standard && model.state.modifiers == "⌃⌥⌘")
        shortcuts.taken = .standard
        model.registerShortcuts()
        #expect(
            model.shortcutError
                == "⌃⌥⌘ + Space is already used by another app. Choose other modifier keys."
        )
        model.retryModels()
        try await loaded(model)
        #expect(!model.shortcutError.isEmpty && model.catalogError.isEmpty)
        shortcuts.taken = nil
        model.registerShortcuts()
        #expect(model.shortcutError.isEmpty && shortcuts.registered == [.standard])
        model.configureShortcuts()
        #expect(model.configuringShortcuts && shortcuts.unregistered == 0)
        #expect(throws: AppFailure.self) { try model.saveShortcutModifiers(.command) }
        shortcuts.taken = [.control, .option]
        #expect(throws: AppFailure.self) { try model.saveShortcutModifiers([.control, .option]) }
        #expect(model.configuringShortcuts && model.shortcutModifiers == .standard)
        #expect(defaults.integer(forKey: "shortcutModifiers") == ShortcutModifiers.command.rawValue)
        try model.saveShortcutModifiers([.control, .shift])
        #expect(!model.configuringShortcuts && model.shortcutModifiers == [.control, .shift])
        #expect(model.state.modifiers == "⌃⇧" && shortcuts.registered.last == [.control, .shift])
        model.state.live = true
        let retained = model.state
        #expect(model.canConfigureShortcuts)
        model.configureShortcuts()
        #expect(model.configuringShortcuts && shortcuts.unregistered == 0)
        shortcuts.taken = .standard
        #expect(throws: AppFailure.self) { try model.saveShortcutModifiers(.standard) }
        #expect(model.shortcutModifiers == [.control, .shift] && model.state == retained)
        shortcuts.taken = nil
        try model.saveShortcutModifiers([.option, .command])
        #expect(model.state.live && model.state.modifiers == "⌥⌘")
        model.state.live = false
        await model.shutdown()
        #expect(shortcuts.unregistered == 1)
        let restored = configuredModel(
            session: http, storage: accountStore.storage, defaults: defaults)
        try await loaded(restored)
        #expect(restored.shortcutModifiers == [.option, .command])
        #expect(restored.state.modifiers == "⌥⌘")
        await restored.shutdown()
    }

    @Test func accessSaveIsAtomicAndDisablingRetainsPerOriginCredentials() async throws {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        defaults.set("HTTPS://VIEWER.EXAMPLE.INVALID:443/", forKey: "relayURL")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let accountStore = RecoveryAccountStore(session: tokens())
        let model = configuredModel(
            session: http, storage: accountStore.storage, defaults: defaults,
            viewerAccessStorage: store.storage)
        try await loaded(model)
        model.setViewerAccessEnabled(true)
        #expect(model.viewerSetupWarning == .setupRequired)
        model.configureViewerAccess()
        #expect(model.configuringViewerAccess)
        let credentials = ViewerAccessCredentials(
            origin: "https://viewer.example.invalid", clientID: "test-client.access",
            clientSecret: "test-secret")
        var invalid = credentials
        invalid.clientSecret = ""
        #expect(throws: ViewerFailure.invalidClientSecret) { try model.saveViewerAccess(invalid) }
        #expect(model.configuringViewerAccess && model.viewerCredentials == nil)
        #expect(store.savedCredentials.isEmpty && model.viewerSetupRequired)
        try model.saveViewerAccess(credentials)
        #expect(!model.configuringViewerAccess && model.viewerCredentials == credentials)
        #expect(model.viewerSetupWarning == nil && model.viewerSetupIssue == nil)
        #expect(store.savedCredentials == [credentials])
        #expect(store.record(for: credentials.origin) == credentials)
        #expect(!model.viewerSetupRequired && model.canStartSession)
        model.setViewerAccessEnabled(false)
        #expect(model.viewerCredentials == credentials && !model.viewerAccessEnabled)
        #expect(model.viewerSetupWarning == nil)
        #expect(store.record(for: credentials.origin) == credentials)
        #expect(!defaults.bool(forKey: "viewerAccessEnabled"))
        await model.shutdown()
        let reads = store.loadedOrigins.count
        let restored = configuredModel(
            session: http, storage: accountStore.storage, defaults: defaults,
            viewerAccessStorage: store.storage)
        try await loaded(restored)
        #expect(!restored.viewerAccessEnabled && restored.viewerCredentials == nil)
        #expect(store.loadedOrigins.count == reads && restored.canStartSession)
        restored.setViewerAccessEnabled(true)
        #expect(restored.viewerCredentials == credentials && !restored.viewerSetupRequired)
        await restored.shutdown()
        let enabledRestored = configuredModel(
            session: http, storage: accountStore.storage, defaults: defaults,
            viewerAccessStorage: store.storage)
        try await loaded(enabledRestored)
        #expect(
            enabledRestored.viewerAccessEnabled && enabledRestored.viewerCredentials == credentials)
        #expect(enabledRestored.canStartSession && enabledRestored.status == "Ready")
        await enabledRestored.shutdown()
    }

    @Test func accessEndpointChangesNeverReuseAnotherOriginsCredentials() async throws {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        let first = ViewerAccessCredentials(
            origin: "https://first.example.invalid", clientID: "first.access",
            clientSecret: "first-secret")
        let second = ViewerAccessCredentials(
            origin: "https://second.example.invalid:8443", clientID: "second.access",
            clientSecret: "second-secret")
        store.inject(first, for: first.origin)
        store.inject(second, for: second.origin)
        defaults.set(first.origin, forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(model.viewerCredentials == first && model.canStartSession)
        model.setViewerEndpoint("https://new.example.invalid")
        #expect(model.viewerCredentials == nil && model.viewerSetupRequired)
        #expect(model.viewerAccessEnabled && !model.canStartSession)
        #expect(throws: ViewerFailure.setupRequired) { try model.saveViewerAccess(first) }
        #expect(store.savedCredentials.isEmpty && store.record(for: first.origin) == first)
        model.setViewerEndpoint(second.origin)
        #expect(model.viewerCredentials == second && model.canStartSession)
        model.setViewerEndpoint("HTTPS://FIRST.EXAMPLE.INVALID:443/")
        #expect(model.viewerCredentials == first && model.canStartSession)
        #expect(
            store.loadedOrigins == [
                first.origin, "https://new.example.invalid", second.origin, first.origin,
            ])
        model.setViewerAccessEnabled(false)
        let reads = store.loadedOrigins.count
        model.setViewerEndpoint(second.origin)
        #expect(store.loadedOrigins.count == reads && model.canStartSession)
        model.setViewerAccessEnabled(true)
        #expect(model.viewerCredentials == second)
        await model.shutdown()
    }

    @Test func accessKeychainFailuresKeepTheEnabledModeAndPreviousRecord() async throws {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        let previous = ViewerAccessCredentials(
            origin: "https://viewer.example.invalid", clientID: "previous.access",
            clientSecret: "previous-secret")
        store.inject(previous, for: previous.origin)
        defaults.set(previous.origin, forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        store.rejectLoads(true)
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(model.viewerAccessEnabled && defaults.bool(forKey: "viewerAccessEnabled"))
        #expect(
            model.viewerCredentials == nil && model.viewerSetupRequired && !model.canStartSession)
        #expect(model.viewerFailure == .credentialsUnavailable && model.error.contains("Keychain"))
        #expect(store.record(for: previous.origin) == previous && store.savedCredentials.isEmpty)
        model.configureViewerAccess()
        #expect(model.configuringViewerAccess && model.viewerCredentials == nil)
        store.rejectLoads(false)
        model.configuringViewerAccess = false
        model.configureViewerAccess()
        #expect(model.viewerCredentials == previous)
        #expect(model.viewerFailure == nil && model.error.isEmpty)
        store.rejectSaves(true)
        let next = ViewerAccessCredentials(
            origin: previous.origin, clientID: "next.access", clientSecret: "next-secret")
        #expect(throws: ViewerFailure.credentialsNotSaved) { try model.saveViewerAccess(next) }
        #expect(model.configuringViewerAccess && model.viewerCredentials == previous)
        #expect(store.record(for: previous.origin) == previous && store.savedCredentials.isEmpty)
        #expect(model.viewerAccessEnabled && defaults.bool(forKey: "viewerAccessEnabled"))
        store.rejectSaves(false)
        try model.saveViewerAccess(next)
        #expect(model.viewerCredentials == next && store.record(for: previous.origin) == next)
        #expect(model.viewerFailure == nil && model.error.isEmpty && model.canStartSession)
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func accessRejectsMalformedInjectedCredentialRecords(_ wrongOrigin: Bool) async throws {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        let origin = "https://viewer.example.invalid"
        let malformed = ViewerAccessCredentials(
            origin: wrongOrigin ? "https://other.example.invalid" : origin,
            clientID: "test.access",
            clientSecret: wrongOrigin ? "test-secret" : "secret\r\nforged: value")
        store.inject(malformed, for: origin)
        defaults.set(origin, forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(model.viewerAccessEnabled && model.viewerCredentials == nil)
        #expect(model.viewerSetupRequired && !model.canStartSession)
        #expect(model.viewerFailure == .credentialsUnavailable)
        #expect(store.record(for: origin) == malformed && store.savedCredentials.isEmpty)
        await model.shutdown()
    }

    @Test func accessControlsAllowAccountLoadingButFreezeUntilSessionTeardownFinishes() async throws
    {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        let credentials = ViewerAccessCredentials(
            origin: "https://viewer.example.invalid", clientID: "test.access",
            clientSecret: "test-secret")
        store.inject(credentials, for: credentials.origin)
        defaults.set(credentials.origin, forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        let initialReads = store.loadedOrigins.count
        #expect(model.working && model.canConfigureViewer)
        model.setViewerAccessEnabled(false)
        #expect(!model.viewerAccessEnabled)
        model.setViewerAccessEnabled(true)
        model.configureViewerAccess()
        #expect(model.configuringViewerAccess && model.viewerCredentials == credentials)
        try model.saveViewerAccess(credentials)
        #expect(model.viewerAccessEnabled && !model.configuringViewerAccess)
        #expect(store.loadedOrigins.count > initialReads && store.savedCredentials == [credentials])
        try await loaded(model)
        model.state.live = true
        #expect(!model.canConfigureViewer)
        model.setViewerAccessEnabled(false)
        model.configureViewerAccess()
        #expect(throws: ViewerFailure.setupRequired) { try model.saveViewerAccess(credentials) }
        #expect(model.viewerAccessEnabled && model.viewerCredentials == credentials)
        #expect(!model.configuringViewerAccess && store.savedCredentials == [credentials])
        let ending = model.endSession()
        #expect(model.working && !model.canConfigureViewer)
        model.setViewerAccessEnabled(false)
        model.configureViewerAccess()
        #expect(throws: ViewerFailure.setupRequired) { try model.saveViewerAccess(credentials) }
        await ending.value
        #expect(model.canConfigureViewer)
        model.setViewerAccessEnabled(false)
        #expect(!model.viewerAccessEnabled && !defaults.bool(forKey: "viewerAccessEnabled"))
        await model.shutdown()
    }

    @Test func invalidViewerEndpointCannotOpenConfigurationAndAValidOriginRestoresIt() async throws
    {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        defaults.set("https://viewer.example.invalid/rooms", forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(model.canConfigureViewer && model.viewerEndpoint == nil)
        #expect(model.viewerSetupRequired && !model.canStartSession)
        model.configureViewerAccess()
        #expect(!model.configuringViewerAccess && store.loadedOrigins.isEmpty)
        model.showError(ViewerFailure.setupRequired)
        #expect(!model.canRecover)
        model.recover()
        #expect(!model.configuringViewerAccess)
        model.setViewerAccessEnabled(false)
        #expect(!model.viewerAccessEnabled && model.viewerSetupRequired)
        model.setViewerAccessEnabled(true)
        model.setViewerEndpoint("https://viewer.example.invalid")
        #expect(model.viewerEndpoint?.origin == "https://viewer.example.invalid")
        model.configureViewerAccess()
        #expect(model.configuringViewerAccess && model.viewerCredentials == nil)
        #expect(
            store.loadedOrigins == [
                "https://viewer.example.invalid", "https://viewer.example.invalid",
            ])
        await model.shutdown()
    }

    @Test func invalidEndpointSetupWarningSurvivesAccessOffWithoutBecomingAnOperationalError()
        async throws
    {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        defaults.set("https://viewer.example.invalid/rooms", forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(
            model.viewerSetupIssue == .invalidEndpoint
                && model.viewerSetupWarning == .invalidEndpoint)
        #expect(model.status == "Setup required" && !model.canStartSession)
        #expect(model.error.isEmpty && model.catalogError.isEmpty && model.state.error.isEmpty)
        #expect(model.feedback == nil && model.viewerFailure == nil)
        model.setViewerAccessEnabled(false)
        #expect(!model.viewerAccessEnabled && model.viewerSetupIssue == .invalidEndpoint)
        #expect(model.viewerSetupWarning == .invalidEndpoint && !model.canStartSession)
        model.setViewerEndpoint("https://viewer.example.invalid")
        #expect(model.viewerSetupIssue == nil && model.viewerSetupWarning == nil)
        #expect(model.status == "Ready" && model.canStartSession)
        #expect(model.error.isEmpty && model.catalogError.isEmpty && model.state.error.isEmpty)
        #expect(store.loadedOrigins.isEmpty && store.savedCredentials.isEmpty)
        await model.shutdown()
    }

    @Test(arguments: ["chatgpt", "viewer", "catalog"])
    func operationalNoticesKeepPriorityAndDiagnosticsOverDerivedSetupWarnings(_ kind: String)
        async throws
    {
        let store = RecoveryViewerStore()
        let defaults = TestDefaults()
        defaults.set("https://viewer.example.invalid", forKey: "relayURL")
        defaults.set(true, forKey: "viewerAccessEnabled")
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage,
            defaults: defaults, viewerAccessStorage: store.storage)
        try await loaded(model)
        #expect(model.viewerSetupWarning == .setupRequired && model.error.isEmpty)
        let failure: Error =
            kind == "viewer"
            ? ViewerFailure.accessDenied
            : ChatGPTFailure(
                status: 503,
                body: Data(
                    "{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}".utf8),
                requestID: "setup-warning-request")
        model.showError(failure, catalog: kind == "catalog")
        let operationalError = model.error
        let catalogError = model.catalogError
        let stateError = model.state.error
        #expect(model.viewerSetupWarning == nil && model.viewerSetupIssue == .setupRequired)
        if kind == "catalog" {
            #expect(operationalError.isEmpty && !catalogError.isEmpty)
        } else {
            #expect(!operationalError.isEmpty && catalogError.isEmpty)
        }
        model.setViewerEndpoint("https://viewer.example.invalid/path")
        #expect(model.viewerSetupIssue == .invalidEndpoint && model.viewerSetupWarning == nil)
        #expect(model.error == operationalError && model.catalogError == catalogError)
        #expect(model.state.error == stateError)
        model.setViewerEndpoint("https://viewer.example.invalid")
        #expect(model.viewerSetupIssue == .setupRequired && model.viewerSetupWarning == nil)
        #expect(model.error == operationalError && model.catalogError == catalogError)
        if kind == "viewer" {
            #expect(model.viewerFailure == .accessDenied && model.feedback == nil)
            model.configureViewerAccess()
            #expect(model.configuringViewerAccess && model.viewerSetupWarning == nil)
            try model.saveViewerAccess(
                ViewerAccessCredentials(
                    origin: "https://viewer.example.invalid", clientID: "test.access",
                    clientSecret: "test-secret"))
            #expect(model.viewerSetupIssue == nil && model.viewerSetupWarning == nil)
        } else {
            #expect(
                model.feedback?.status == 503
                    && model.feedback?.requestID == "setup-warning-request")
            #expect(model.feedback?.code == "subscription_sharing_usage_unavailable")
            #expect(
                model.feedback?.diagnostic.contains("Request ID: setup-warning-request") == true)
            model.retryModels()
            try await loaded(model)
            #expect(
                model.viewerSetupIssue == .setupRequired
                    && model.viewerSetupWarning == .setupRequired)
        }
        #expect(model.error.isEmpty && model.catalogError.isEmpty && model.state.error.isEmpty)
        #expect(model.feedback == nil && model.viewerFailure == nil)
        await model.shutdown()
    }

    @Test func failedInvalidGrantTokenRemovalStillStopsTheLiveSession() async throws {
        let stored = RecoveryAccountStore(session: tokens(expired: true))
        let http = session(code: "models-rotating")
        defer { http.invalidateAndCancel() }
        let defaults = TestDefaults()
        let client = ChatGPT(session: http, storage: stored.storage, defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await loaded(model)
        try #require(
            model.canStartSession && stored.current?.session?.refreshToken == "rotated-refresh")
        model.state.live = true
        model.state.beginAnswer(id: "received-answer", language: "English")
        model.state.answers[0].text = "A received answer that must survive"
        model.state.answers[0].status = "complete"
        let retained = model.state.answers
        stored.rejectSaves(true)
        do {
            _ = try await client.listModels()
            Issue.record("Revoked credentials with failed Keychain removal were accepted")
        } catch let failure as ChatGPTFailure {
            #expect(failure.stopsSession && failure.message.contains("Keychain"))
        }
        try await loaded(model)
        #expect(!model.state.live && !model.canAnswer && model.state.answers == retained)
        #expect(model.account.isEmpty && model.models.isEmpty && client.account?.session == nil)
        #expect(model.canAuthenticate && model.canConfigureViewer)
        #expect(model.feedback?.stopsSession == true && model.error.contains("Keychain"))
        #expect(
            stored.current?.session?.refreshToken == "rotated-refresh" && stored.writeCount == 1)
        await model.shutdown()
    }

    @Test(arguments: [
        "sign-in", "plan", "invalid_grant", "invalid_client", "subscription_sharing_invalid_user",
        "subscription_sharing_user_not_eligible", "chatpass_v2_scope_not_authorized",
        "chatpass_v2_invalid_authorization_context", "http-401", "token-removal", "access",
    ])
    func terminalAuthorizationFailuresStopAndPreserveCompletedAndPendingAnswers(_ reason: String)
        async throws
    {
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "saved-answer", language: "English")
        model.state.answers[0].text = "Keep this answer"
        model.state.answers[0].status = "complete"
        model.answer()
        try #require(model.state.answers.count == 2 && model.answering)
        model.state.answers[1].text = "Useful partial answer"
        model.link = URL(string: "https://viewer.example.invalid/#test-link")
        let failure: Error
        switch reason {
        case "sign-in": failure = ChatGPTFailure.signInRequired
        case "plan": failure = ChatGPTFailure.planDisabled
        case "access": failure = ViewerFailure.accessDenied
        case "http-401": failure = ChatGPTFailure(status: 401)
        case "token-removal": failure = ChatGPTFailure.tokenRemovalFailed
        default:
            failure = ChatGPTFailure(
                status: ["invalid_grant", "invalid_client"].contains(reason) ? 400 : 403,
                body: Data("{\"error\":{\"code\":\"\(reason)\"}}".utf8))
        }
        model.showError(failure)
        #expect(!model.state.live && model.working && model.status == "Stopping…")
        #expect(!model.canAnswer && !model.canConfigureViewer && !model.canAuthenticate)
        #expect(model.link == nil && model.state.answers.count == 2)
        #expect(
            model.state.answers[0].text == "Keep this answer"
                && model.state.answers[0].status == "complete")
        #expect(
            model.state.answers[1].text == "Useful partial answer"
                && model.state.answers[1].status == "incomplete")
        let message = model.error
        try await loaded(model)
        await Task.yield()
        #expect(model.canConfigureViewer && model.canAuthenticate && !model.canAnswer)
        #expect(model.error == message && !message.isEmpty && model.state.answers.count == 2)
        #expect(
            model.state.answers[1].text == "Useful partial answer"
                && model.state.answers[1].status == "incomplete")
        if ["sign-in", "plan", "invalid_grant", "access"].contains(reason) {
            #expect(model.canRecover)
        }
        await model.shutdown()
    }

    @Test(arguments: [
        "subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable",
        "subscription_sharing_user_unavailable", "subscription_sharing_unsupported_capability",
        "credential-save", "generic",
    ])
    func recoverableAnswerAndStorageFailuresKeepTheSession(_ reason: String) async throws {
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(
            session: http, storage: RecoveryAccountStore(session: tokens()).storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "saved", language: "English")
        model.state.answers[0].text = "Existing answer"
        model.state.answers[0].status = "complete"
        let retained = model.state.answers
        let failure: Error
        switch reason {
        case "credential-save": failure = ChatGPTFailure.credentialsNotSaved
        case "generic": failure = ChatGPTFailure.generic
        default:
            failure = ChatGPTFailure(
                status: reason == "subscription_sharing_usage_limit_exceeded"
                    ? 429
                    : reason == "subscription_sharing_unsupported_capability" ? 400 : 503,
                body: Data("{\"error\":{\"code\":\"\(reason)\"}}".utf8))
        }
        model.showError(failure)
        #expect(model.state.live && !model.working && model.state.answers == retained)
        #expect(model.canAnswer && !model.canConfigureViewer && !model.canAuthenticate)
        await Task.yield()
        #expect(model.state.live && model.state.answers == retained && !model.error.isEmpty)
        await model.shutdown()
    }
}
