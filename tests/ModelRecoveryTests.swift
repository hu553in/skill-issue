import Foundation
import Testing

@testable import SkillIssue

private final class RecoveryAccountStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTAccounts?
    private var failLoad = false
    private var writes = 0
    init(session: ChatGPTSession?) {
        value = ChatGPTAccounts(
            account: ChatGPTAccount(
                clientID: "test-client", subject: "test-subject", email: "test@example.invalid",
                session: session))
    }
    init(accounts: ChatGPTAccounts) { value = accounts }
    func rejectNextLoad() { lock.withLock { failLoad = true } }
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
                lock.withLock {
                    value = account
                    writes += 1
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
        let code = refresh ? "invalid_grant" : request.value(forHTTPHeaderField: "X-Recovery-Test")!
        let catalog = code == "models"
        let body =
            catalog
            ? "{\"models\":[{\"slug\":\"gpt-6-luna\",\"display_name\":\"GPT-6 Luna\",\"visibility\":\"list\",\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}]},{\"slug\":\"gpt-6-sol\",\"display_name\":\"GPT-6 Sol\",\"visibility\":\"list\",\"supported_reasoning_levels\":[{\"effort\":\"low\"}]}]}"
            : refresh ? "{\"error\":\"\(code)\"}" : "{\"error\":{\"code\":\"\(code)\"}}"
        let response = HTTPURLResponse(
            url: url, statusCode: catalog ? 200 : refresh ? 400 : 503, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "x-request-id": "test-request"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct ModelRecoveryTests {
    private func configuredModel(session: URLSession, storage: AccountStorage) -> Model {
        let defaults = TestDefaults()
        return Model(
            chatGPT: ChatGPT(
                session: session, storage: storage, defaults: defaults,
                openAuthorization: { _ in false }),
            defaults: defaults)
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
    private func loaded(_ model: Model) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.working, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.working)
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
        #expect(model.recoveryHint == "Stop the session to enable ChatGPT plan usage.")
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
        "subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
        "subscription_sharing_unsupported_capability",
    ])
    func manualRetryKeepsLiveAnswersWithoutAutomaticReplay(_ code: String) async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "saved-answer")
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
        model.state.beginAnswer(id: "saved-answer")
        model.state.answers[0].text = "Partial answer"
        let body = Data("{\"error\":{\"code\":\"subscription_sharing_usage_unavailable\"}}".utf8)
        model.showError(ChatGPTFailure(status: 503, body: body))
        #expect(model.canAnswer && model.canRecover && model.recoveryTitle == "Request answer")
        await Task.yield()
        #expect(model.state.live && model.state.answers.count == 1)
        #expect(model.state.answers[0].text == "Partial answer")
        await model.shutdown()
    }

    @Test func liveModelSelectionIsAvailableBetweenRequestsOnly() async throws {
        let stored = RecoveryAccountStore(session: tokens())
        let http = session(code: "models")
        defer { http.invalidateAndCancel() }
        let model = configuredModel(session: http, storage: stored.storage)
        try await loaded(model)
        model.state.live = true
        model.state.beginAnswer(id: "existing")
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
        model.state.beginAnswer(id: "generating")
        model.state.select(-1)
        #expect(model.state.selectedID == "existing" && model.status == "Thinking…")
        #expect(!model.canSelectModel && !model.canSelectEffort)
        model.selectModel("gpt-6-luna")
        #expect(model.modelSlug == "gpt-6-sol")
        model.state.answers[1].status = "failed"
        #expect(model.canSelectModel)
        #expect(model.status == "Listening")
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
}
