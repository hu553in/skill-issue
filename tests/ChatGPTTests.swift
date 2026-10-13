import Foundation
@preconcurrency import Network
import Testing

@testable import SkillIssue

@MainActor private final class CallbackPeerState {
    var connected = false
    var closed = false
}

private final class StoredAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTAccounts?
    private var log: [String] = []
    var rejectSave = false
    init(expired: Bool = false) {
        value = ChatGPTAccounts(
            account: ChatGPTAccount(
                clientID: "fake-client", subject: "fake-subject", email: "fake@example.invalid",
                session: ChatGPTSession(
                    idToken: "fake-id", accessToken: "old-access", refreshToken: "old-refresh",
                    expires: expired ? .distantPast : Date().addingTimeInterval(3600),
                    scopes: ["chatgpt.tokens.use.direct"])))
    }
    var events: [String] { lock.withLock { log } }
    var current: ChatGPTAccount? { lock.withLock { value?.selected } }
    var storage: AccountStorage {
        AccountStorage(
            load: { [self] in lock.withLock { value } },
            save: { [self] next in
                try lock.withLock {
                    if rejectSave { throw AppFailure.failed }
                    value = next
                    log.append("save:\(next.selected?.session?.refreshToken ?? "signed-out")")
                }
            })
    }
}

private func catalogModel(
    _ slug: String, name: String? = nil, visibility: String = "list",
    efforts: [String]? = ["low", "medium", "high"]
) -> [String: Any] {
    var fields: [String: Any] = [
        "slug": slug, "display_name": name ?? slug, "visibility": visibility,
    ]
    if let efforts {
        fields["supported_reasoning_levels"] = efforts.map { ["effort": $0] }
    }
    return fields
}

private final class TestHTTP: @unchecked Sendable {
    enum Output: Sendable { case text, refusal, empty, whitespace }
    private let lock = NSLock()
    private var refresh: MockHTTPProtocol?
    private var modelRequests = 0
    private var catalog: [[String: Any]]
    private var catalogStatus = 200
    private var catalogCode: String?
    private var responseBodies: [[String: Any]] = []
    private var responseRequests: [URLRequest] = []
    private var responseCancellations = 0
    private var revocationRequests = 0
    private var refreshRequests = 0
    private var revocationTokens: [String] = []
    private let refreshError: String?
    private let refreshStatus: Int
    private let revocationStatuses: [Int]
    private let revocationNetworkFailure: Bool
    private let output: Output
    private let stream: [Data]?
    private let finishStream: Bool
    private let responseStatus: Int
    private let responseStreamFailure: Bool
    private let droppedJSONError: (path: String, body: Data, status: Int)?
    init(
        output: Output = .empty, models: [[String: Any]] = [catalogModel("gpt-6-luna")],
        stream: [Data]? = nil, finishStream: Bool = true, responseStatus: Int = 200,
        refreshError: String? = nil, refreshStatus: Int = 400, revocationStatuses: [Int] = [200],
        revocationNetworkFailure: Bool = false, responseStreamFailure: Bool = false,
        droppedJSONError: (path: String, body: Data, status: Int)? = nil
    ) {
        self.output = output
        catalog = models
        self.stream = stream
        self.finishStream = finishStream
        self.responseStatus = responseStatus
        self.responseStreamFailure = responseStreamFailure
        self.droppedJSONError = droppedJSONError
        self.refreshError = refreshError
        self.refreshStatus = refreshStatus
        self.revocationStatuses = revocationStatuses
        self.revocationNetworkFailure = revocationNetworkFailure
    }
    var refreshPending: Bool { lock.withLock { refresh != nil } }
    var modelsRequested: Int { lock.withLock { modelRequests } }
    var requests: [[String: Any]] { lock.withLock { responseBodies } }
    var wireRequests: [URLRequest] { lock.withLock { responseRequests } }
    var cancelledResponses: Int { lock.withLock { responseCancellations } }
    var refreshes: Int { lock.withLock { refreshRequests } }
    var revokedTokens: [String] { lock.withLock { revocationTokens } }
    var revocations: Int { lock.withLock { revocationRequests } }
    func cancelled(_ request: URLRequest) {
        if request.url?.path == "/v1/responses" {
            lock.withLock { responseCancellations += 1 }
        }
    }
    func setCatalog(_ models: [[String: Any]], status: Int = 200, code: String? = nil) {
        lock.withLock {
            catalog = models
            catalogStatus = status
            catalogCode = code
        }
    }
    func rejectPendingRefresh(code: String? = "invalid_grant", status: Int = 400) {
        let pending = lock.withLock {
            let pending = refresh
            refresh = nil
            return pending
        }
        pending?.respond(code.map { ["error": $0] } ?? [:], status: status)
    }
    func finishRefresh(
        includeScope: Bool = true, expiresIn: Int = 3600,
        scope: Any = "chatgpt.tokens.use.direct", refreshToken: String = "replacement-refresh"
    ) {
        let pending = lock.withLock {
            let pending = refresh
            refresh = nil
            return pending
        }
        var tokens: [String: Any] = [
            "access_token": "replacement-access", "refresh_token": refreshToken,
            "expires_in": expiresIn, "token_type": "bearer",
        ]
        if includeScope { tokens["scope"] = scope }
        pending?.respond(tokens)
    }
    func receive(_ request: MockHTTPProtocol) throws {
        if let failure = droppedJSONError, request.request.url?.path == failure.path {
            request.respond(
                [failure.body], contentType: "application/json", status: failure.status,
                failAfterBody: true)
            return
        }
        switch request.request.url!.path {
        case "/v1/models":
            let (models, status, code) = lock.withLock {
                modelRequests += 1
                return (catalog, catalogStatus, catalogCode)
            }
            if let code {
                request.respond(["error": ["code": code, "param": "model"]], status: status)
            } else {
                request.respond(["models": models], status: status)
            }
        case "/api/accounts/oauth/token":
            lock.withLock { refreshRequests += 1 }
            if let refreshError {
                request.respond(["error": refreshError], status: refreshStatus)
            } else {
                lock.withLock { refresh = request }
            }
        case "/.well-known/openid-configuration":
            request.respond([
                "issuer": "https://auth.openai.com",
                "revocation_endpoint": "https://auth.openai.com/revoke",
            ])
        case "/revoke":
            let body = String(data: try requestBody(request.request), encoding: .utf8) ?? ""
            let status = lock.withLock {
                revocationRequests += 1
                revocationTokens.append(body)
                return revocationStatuses[min(revocationRequests - 1, revocationStatuses.count - 1)]
            }
            if revocationNetworkFailure {
                request.client?.urlProtocol(
                    request, didFailWithError: URLError(.notConnectedToInternet))
            } else {
                request.respond(Data(), contentType: "application/json", status: status)
            }
        case "/v1/responses":
            lock.withLock { responseRequests.append(request.request) }
            let body = try requestBody(request.request)
            if let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                lock.withLock { responseBodies.append(payload) }
            }
            if let stream {
                request.respond(
                    stream, contentType: "text/event-stream", status: responseStatus,
                    finished: finishStream, failAfterBody: responseStreamFailure)
                return
            }
            let refusal = "I cannot assist with that request."
            var events: [[String: Any]] = []
            if output == .refusal {
                events += [
                    ["type": "response.refusal.delta", "delta": refusal],
                    ["type": "response.refusal.done", "refusal": refusal],
                ]
            } else if output == .text {
                events.append([
                    "type": "response.output_text.delta", "delta": "Use constant auxiliary space.",
                ])
            } else if output == .whitespace {
                events.append(["type": "response.output_text.delta", "delta": " \n\t"])
            }
            events.append(["type": "response.completed", "response": ["status": "completed"]])
            let data = events.reduce(into: Data()) { data, event in
                data.append(Data("data: ".utf8))
                // Fixture dictionaries contain only JSON-compatible values.
                // swiftlint:disable:next force_try
                data.append(try! JSONSerialization.data(withJSONObject: event))
                data.append(Data("\n\n".utf8))
            }
            request.respond(data, contentType: "text/event-stream")
        default: request.client?.urlProtocol(request, didFailWithError: AppFailure.failed)
        }
    }
}

private final class MockHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var server: TestHTTP?
    private let stateLock = NSLock()
    private var receiver: TestHTTP?
    static func session(server: TestHTTP) -> URLSession {
        lock.withLock { Self.server = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let server = Self.lock.withLock { Self.server }
        stateLock.withLock { receiver = server }
        do {
            try server?.receive(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { stateLock.withLock { receiver }?.cancelled(request) }
    func respond(_ value: [String: Any], status: Int = 200) {
        // Fixture dictionaries contain only JSON-compatible values.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: value)
        respond(data, contentType: "application/json", status: status)
    }
    func respond(_ data: Data, contentType: String, status: Int = 200) {
        respond([data], contentType: contentType, status: status)
    }
    func respond(
        _ chunks: [Data], contentType: String, status: Int = 200, finished: Bool = true,
        failAfterBody: Bool = false
    ) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "x-request-id": "fixture-request"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if failAfterBody {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else if finished {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite(.serialized) @MainActor
struct ChatGPTTests {
    @Test func terminalRefreshRequiresSignInAndTemporaryFailureKeepsCredentials() async throws {
        for (code, status, terminal) in [
            ("invalid_grant", 400, true), ("invalid_refresh_token", 400, true),
            ("token_expired", 400, true), ("refresh_token_expired", 400, true),
            ("refresh_token_invalidated", 400, true), ("refresh_token_reused", 400, true),
            ("invalid_client", 400, false), ("temporarily_unavailable", 503, false),
        ] {
            let stored = StoredAccount(expired: true)
            let server = TestHTTP(refreshError: code, refreshStatus: status)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = ChatGPT(
                session: session, storage: stored.storage, defaults: TestDefaults())
            try await chatGPT.restore()
            do {
                _ = try await chatGPT.listModels()
                Issue.record("A failed refresh was accepted")
            } catch {}
            #expect((chatGPT.account?.session == nil) == terminal)
            #expect((stored.current?.session == nil) == terminal)
            #expect(stored.current?.clientID == "fake-client")
            #expect(stored.current?.subject == "fake-subject")
            do { _ = try await chatGPT.listModels() } catch {}
            #expect(server.refreshes == (terminal ? 1 : 2))
        }
    }

    @Test func failedRemoteRevocationRetriesBeforeLocalSignOut() async throws {
        let stored = StoredAccount()
        let server = TestHTTP(revocationStatuses: [503])
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let confirmed = try await chatGPT.signOut()
        #expect(!confirmed)
        #expect(server.revocations == 3)
        #expect(chatGPT.account?.session == nil && stored.current?.session == nil)
        #expect(
            stored.current?.clientID == "fake-client" && stored.current?.subject == "fake-subject")
    }

    @Test func failedSessionStopsControlsAndKeepsPartialAnswer() async throws {
        let account = ChatGPTAccount(
            clientID: "fake-client", subject: "fake-subject", email: "fake@example.invalid",
            session: ChatGPTSession(
                idToken: "fake-id", accessToken: "fake-access", refreshToken: "fake-refresh",
                expires: Date().addingTimeInterval(3600), scopes: ["chatgpt.tokens.use.direct"]))
        let session = MockHTTPProtocol.session(server: TestHTTP())
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(
            session: session,
            storage: AccountStorage(load: { ChatGPTAccounts(account: account) }, save: { _ in }))
        let model = Model(chatGPT: chatGPT, defaults: TestDefaults())
        let deadline = ContinuousClock.now + .seconds(3)
        while model.working, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.working)

        model.state.live = true
        model.answer()
        model.state.answers[0].text = "A partial suggestion"
        model.link = URL(string: "https://example.invalid")
        let ending = model.endSession(failed: true)
        #expect(!model.canAnswer)
        #expect(model.link == nil)
        let command = model.state.command
        model.scroll(1)
        model.navigate(-1)
        model.answer()
        #expect(model.state.command == command)
        await ending.value
        #expect(!model.state.live && !model.working)
        #expect(model.status == "Ready")
        #expect(model.state.error == failureMessage)
        #expect(model.state.answers.count == 1)
        #expect(model.state.answers[0].text == "A partial suggestion")
        #expect(model.state.answers[0].status == "incomplete")
        // Repeated cleanup and a later cancelled callback must not re-enable controls.
        await model.shutdown()
        #expect(!model.canAnswer)
        #expect(model.state.answers[0].status == "incomplete")
    }

    @Test func revocationRetriesOnlyTemporaryFailuresAndAcceptsEmptySuccess() async throws {
        for (statuses, networkFailure, expectedRequests, confirmed) in [
            ([200], false, 1, true), ([503, 200], false, 2, true),
            ([503, 503, 200], false, 3, true), ([400], false, 1, false),
            ([200], true, 3, false),
        ] {
            let stored = StoredAccount()
            let server = TestHTTP(
                revocationStatuses: statuses, revocationNetworkFailure: networkFailure)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = ChatGPT(
                session: session, storage: stored.storage, defaults: TestDefaults())
            try await chatGPT.restore()
            let result = try await chatGPT.signOut()
            #expect(result == confirmed && server.revocations == expectedRequests)
            #expect(!chatGPT.isSignedIn && stored.current?.session == nil)
            #expect(stored.current?.clientID == "fake-client")
            #expect(server.revokedTokens.allSatisfy { $0.contains("token=old-refresh") })
        }
    }

    @Test func refreshWithoutScopeRetainsGrantedPermission() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let first = Task { try await chatGPT.listModels() }
        let second = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh(includeScope: false)
        _ = try await first.value
        _ = try await second.value
        #expect(server.refreshes == 1 && server.modelsRequested == 2)
        #expect(
            chatGPT.canUsePlan && stored.current?.session?.refreshToken == "replacement-refresh")
    }

    @Test(arguments: ["42", "null", "{}", "[\"chatgpt.tokens.use.direct\"]"])
    func malformedRefreshScopeCannotInheritPermission(_ json: String) async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let request = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh(
            scope: try JSONSerialization.jsonObject(
                with: Data(json.utf8), options: .fragmentsAllowed))
        do {
            _ = try await request.value
            Issue.record("A malformed refresh scope inherited direct plan permission")
        } catch {}
        #expect(server.modelsRequested == 0 && stored.events.isEmpty)
        #expect(chatGPT.account?.session?.accessToken == "old-access")
        #expect(stored.current?.session?.refreshToken == "old-refresh")
        #expect(chatGPT.account?.clientID == "fake-client")
    }

    @Test func emptyRefreshScopeDisablesPlanAndStoresLatestGrant() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let request = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh(scope: "")
        do {
            _ = try await request.value
            Issue.record("An empty refresh scope allowed direct plan usage")
        } catch let failure as ChatGPTFailure {
            #expect(failure.recovery == .enablePlan)
        }
        #expect(chatGPT.isSignedIn && !chatGPT.canUsePlan)
        #expect(chatGPT.account?.session?.scopes.isEmpty == true)
        #expect(stored.current?.session?.refreshToken == "replacement-refresh")
        #expect(stored.events == ["save:replacement-refresh"])
        #expect(server.refreshes == 1 && server.modelsRequested == 0)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Disabled plan usage started a protected request")
        } catch let failure as ChatGPTFailure {
            #expect(failure.recovery == .enablePlan)
        }
        #expect(server.refreshes == 1 && server.modelsRequested == 0)
    }

    @Test func inferenceFailuresKeepCredentialsAndExposeRecoveryWithoutReplay() async throws {
        for (code, status, recovery) in [
            ("subscription_sharing_usage_limit_exceeded", 429, ChatGPTFailure.Recovery.usage),
            ("subscription_sharing_user_not_eligible", 403, .none),
            ("subscription_sharing_usage_unavailable", 503, .retry),
            ("subscription_sharing_user_unavailable", 503, .retry),
            ("subscription_sharing_unsupported_capability", 400, .configuration),
            ("subscription_sharing_route_not_supported", 403, .configuration),
            ("subscription_sharing_invalid_user", 401, .configuration),
            ("chatpass_v2_scope_not_authorized", 403, .configuration),
            ("chatpass_v2_invalid_authorization_context", 403, .configuration),
        ] {
            for shape in ["http", "failed", "error"] {
                let error: [String: Any] = [
                    "code": code, "param": "reasoning.effort", "message": "untrusted server text",
                ]
                let fields: [String: Any]
                switch shape {
                case "failed": fields = ["type": "response.failed", "response": ["error": error]]
                case "error": fields = ["type": "error"].merging(error) { _, new in new }
                default: fields = ["error": error]
                }
                let body = try JSONSerialization.data(withJSONObject: fields)
                let prefix =
                    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n"
                let stream =
                    shape == "http"
                    ? body
                    : Data(
                        (prefix + "data: " + String(decoding: body, as: UTF8.self) + "\n\n").utf8)
                let server = TestHTTP(
                    stream: [stream], responseStatus: shape == "http" ? status : 200)
                let session = MockHTTPProtocol.session(server: server)
                defer { session.invalidateAndCancel() }
                let chatGPT = try await configuredChatGPT(session: session)
                var text = ""
                do {
                    try await chatGPT.answer(
                        input: [], language: "English",
                        model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                    ) { text += $0 }
                    Issue.record("Failed inference was accepted")
                } catch let failure as ChatGPTFailure {
                    #expect(failure.recovery == recovery && failure.code == code)
                    #expect(
                        failure.parameter == "reasoning.effort"
                            && failure.requestID == "fixture-request")
                    #expect(failure.status == (shape == "http" ? status : 200))
                    #expect(failure.responseBody == body)
                    #expect(!failure.message.contains("untrusted server text"))
                }
                #expect(text == (shape == "http" ? "" : "Partial"))
                #expect(chatGPT.isSignedIn && chatGPT.canUsePlan && server.wireRequests.count == 1)
            }
        }
    }

    @Test func plainHTTPDetailDoesNotInventAQuotaReset() async throws {
        let body = Data("{\"detail\":\"Too many requests\"}".utf8)
        let server = TestHTTP(stream: [body], responseStatus: 429)
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = try await configuredChatGPT(session: session)
        do {
            try await chatGPT.answer(
                input: [], language: "English",
                model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
            ) { _ in }
            Issue.record("Rate-limited response was accepted")
        } catch let failure as ChatGPTFailure {
            #expect(failure.status == 429 && failure.code == nil && failure.recovery == .retry)
            #expect(failure.responseBody == body && !failure.message.contains("reset"))
        }
    }

    @Test func directAdmissionDetailReachesModelFeedback() async throws {
        let body = Data(#"{"detail":"The serving region is not supported"}"#.utf8)
        let server = TestHTTP(droppedJSONError: ("/v1/models", body, 403))
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let model = Model(
            chatGPT: ChatGPT(
                session: session, storage: StoredAccount().storage, defaults: TestDefaults()),
            defaults: TestDefaults())
        try await waitUntil { !model.working }
        let feedback = try #require(model.feedback)
        #expect(feedback.responseBody == body && feedback.code == nil)
        #expect(model.recovery == .configuration && model.recoveryTitle == nil)
        #expect(model.canAuthenticate && !model.canStartSession)
        #expect(
            feedback.diagnostic
                == "HTTP 403\nRequest ID: fixture-request\nDetail: The serving region is not supported"
        )
        #expect(model.catalogError.contains("permission or policy restriction"))
        #expect(!model.catalogError.contains("serving region"))
        #expect(model.account == "fake@example.invalid" && server.wireRequests.isEmpty)
        await model.shutdown()
    }

    @Test func directAdmissionDetailIsBoundedPlainTextWithoutQuotaClassification() async throws {
        let readable = "Serving region unavailable.\n  Check the deployment region."
        let cases: [(Any, String?)] = [
            (" \n\(readable)\t ", readable),
            (String(repeating: "x", count: 1200), String(repeating: "x", count: 1000)),
            (
                "subscription_sharing_usage_limit_exceeded resets at 10:00",
                "subscription_sharing_usage_limit_exceeded resets at 10:00"
            ),
            (" \n\t ", nil), (42, nil), (NSNull(), nil), (["message": "restricted"], nil),
        ]
        for (detail, expected) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["detail": detail])
            let server = TestHTTP(stream: [body], responseStatus: 429)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = try await configuredChatGPT(session: session)
            do {
                try await chatGPT.answer(
                    input: [], language: "English",
                    model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                ) { _ in }
                Issue.record("Direct-admission failure was accepted")
            } catch let failure as ChatGPTFailure {
                #expect(failure.status == 429 && failure.code == nil && failure.recovery == .retry)
                #expect(failure.responseBody == body && !failure.message.contains("reset"))
                let diagnostic = "HTTP 429\nRequest ID: fixture-request"
                #expect(
                    failure.diagnostic == diagnostic + (expected.map { "\nDetail: \($0)" } ?? ""))
            }
            #expect(chatGPT.canUsePlan && server.wireRequests.count == 1)
        }
    }

    @Test func existingKeychainRecordMigratesAndSignOutEncodingContainsNoTokens() throws {
        let data = Data(
            "{\"clientID\":\"issued-client\",\"subject\":\"verified-subject\",\"email\":\"test@example.invalid\",\"idToken\":\"identity-secret\",\"accessToken\":\"access-secret\",\"refreshToken\":\"refresh-secret\",\"expires\":800000000}"
                .utf8)
        let migrated = try JSONDecoder().decode(ChatGPTAccounts.self, from: data)
        var account = try #require(migrated.selected)
        #expect(
            account.session?.canUsePlan == true && account.session?.refreshToken == "refresh-secret"
        )
        let updated =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        #expect(updated?["session"] != nil && updated?["idToken"] == nil)
        account.session = nil
        let signedOut = try JSONEncoder().encode(account)
        let record = try #require(
            JSONSerialization.jsonObject(with: signedOut) as? [String: String])
        #expect(
            record == [
                "clientID": "issued-client", "subject": "verified-subject",
                "email": "test@example.invalid",
            ])
        #expect(try JSONDecoder().decode(ChatGPTAccount.self, from: signedOut).session == nil)
        let registryData = try JSONEncoder().encode(ChatGPTAccounts(account: account))
        let restored = try JSONDecoder().decode(ChatGPTAccounts.self, from: registryData)
        #expect(restored.selected?.clientID == "issued-client" && restored.selected?.session == nil)
    }

    private func configuredChatGPT(session: URLSession) async throws -> ChatGPT {
        let chatGPT = ChatGPT(
            session: session, storage: StoredAccount().storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let models = try await chatGPT.listModels()
        try await chatGPT.prepareSession(model: models[0], effort: "low")
        return chatGPT
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test func catalogOrderVisibilityAndDefaults() async throws {
        let cases: [([[String: Any]], String, String, [String])] = [
            (
                [
                    catalogModel("first", efforts: ["high", "low"]),
                    catalogModel("gpt-6-luna", name: "GPT-6 Luna", efforts: ["medium", "low"]),
                ],
                "gpt-6-luna", "low", ["first", "gpt-6-luna"]
            ),
            (
                [
                    catalogModel("gpt-6-luna", visibility: "hidden"),
                    catalogModel("first", efforts: ["high", "medium"]), catalogModel("last"),
                ],
                "first", "high", ["first", "last"]
            ),
            ([catalogModel("plain", efforts: nil)], "plain", "", ["plain"]),
            ([catalogModel("empty", efforts: [])], "empty", "", ["empty"]),
            (
                [catalogModel("filtered", efforts: ["ultra", "future", "none", "high", "none"])],
                "filtered", "none", ["filtered"]
            ),
        ]
        for (catalog, slug, effort, order) in cases {
            let session = MockHTTPProtocol.session(server: TestHTTP(models: catalog))
            defer { session.invalidateAndCancel() }
            let defaults = TestDefaults()
            let model = Model(
                chatGPT: ChatGPT(
                    session: session, storage: StoredAccount().storage,
                    defaults: defaults), defaults: defaults)
            #expect(!model.canSelectModel && !model.canSelectEffort && !model.canStartSession)
            try await waitUntil { !model.working }
            #expect(model.models.map(\.slug) == order)
            #expect(model.modelSlug == slug && model.reasoningEffort == effort)
            #expect(model.canSelectModel && model.canStartSession)
            #expect(model.canSelectEffort == !effort.isEmpty)
            #expect(defaults.string(forKey: "chatGPTModel") == slug)
            if slug == "gpt-6-luna" { #expect(model.selectedModel?.displayName == "GPT-6 Luna") }
            await model.shutdown()
        }
    }

    @Test func modelChangesResetEffortAndValidSelectionsSurviveLaunch() async throws {
        let server = TestHTTP(models: [
            catalogModel("gpt-6-luna", efforts: ["medium", "low"]),
            catalogModel("other", efforts: ["high", "low", "medium"]),
        ])
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let stored = StoredAccount()
        let model = Model(
            chatGPT: ChatGPT(session: session, storage: stored.storage, defaults: defaults),
            defaults: defaults)
        try await waitUntil { !model.working }
        model.selectEffort("medium")
        model.selectModel("other")
        #expect(model.reasoningEffort == "low")
        model.selectEffort("high")
        model.selectModel("missing")
        model.selectEffort("ultra")
        #expect(model.modelSlug == "other" && model.reasoningEffort == "high")
        model.retryModels()
        #expect(model.working && model.status == "Loading models…")
        model.selectModel("gpt-6-luna")
        model.selectEffort("low")
        #expect(!model.canSelectModel && !model.canSelectEffort)
        #expect(model.modelSlug.isEmpty && model.reasoningEffort.isEmpty)
        try await waitUntil { !model.working }
        #expect(model.modelSlug == "other" && model.reasoningEffort == "high")
        model.state.live = true
        model.state.beginAnswer(id: "busy-selection")
        model.selectModel("gpt-6-luna")
        model.selectEffort("low")
        #expect(!model.canSelectModel && !model.canSelectEffort && !model.canStartSession)
        #expect(model.modelSlug == "other" && model.reasoningEffort == "high")
        await model.shutdown()
        let restored = Model(
            chatGPT: ChatGPT(session: session, storage: stored.storage, defaults: defaults),
            defaults: defaults)
        try await waitUntil { !restored.working }
        #expect(restored.modelSlug == "other" && restored.reasoningEffort == "high")
        server.setCatalog([catalogModel("other", efforts: ["medium", "low"])])
        restored.retryModels()
        try await waitUntil { !restored.working }
        #expect(restored.modelSlug == "other" && restored.reasoningEffort == "low")
        server.setCatalog([catalogModel("first", efforts: ["medium"]), catalogModel("gpt-6-luna")])
        restored.retryModels()
        try await waitUntil { !restored.working }
        #expect(restored.modelSlug == "gpt-6-luna" && restored.reasoningEffort == "low")
        await restored.shutdown()
    }

    @Test func effortWithoutSupportedValuesDoesNotPretendToLoadDuringStop() async throws {
        let server = TestHTTP(models: [catalogModel("gpt-6-luna", efforts: [])])
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let model = Model(
            chatGPT: ChatGPT(
                session: session, storage: StoredAccount().storage, defaults: defaults),
            defaults: defaults)
        try await waitUntil { !model.working }
        #expect(model.canStartSession && model.status == "Ready")
        #expect(!model.canSelectEffort && model.effortPlaceholder == "Not available")
        model.state.live = true
        #expect(model.status == "Listening")
        model.viewerStatus = "Viewer connected · 2"
        let stopped = model.endSession()
        #expect(model.working && model.status == "Stopping…")
        #expect(model.effortPlaceholder == "Not available")
        #expect(model.viewerStatus == "Open the viewer on your phone.")
        await stopped.value
        #expect(model.status == "Ready" && model.canStartSession)
        await model.shutdown()
    }

    @Test func catalogFailureKeepsControlsDisabledAndRetryRecovers() async throws {
        let server = TestHTTP()
        server.setCatalog([], status: 503)
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let model = Model(
            chatGPT: ChatGPT(
                session: session, storage: StoredAccount().storage,
                defaults: defaults), defaults: defaults)
        try await waitUntil { !model.working }
        #expect(!model.catalogError.isEmpty && !model.account.isEmpty)
        let invalidCatalogs: [[[String: Any]]] = [
            [], [catalogModel("hidden", visibility: "hidden")],
            [["slug": "missing-name", "visibility": "list"]],
            [catalogModel("duplicate"), catalogModel("duplicate")],
            [
                [
                    "slug": "malformed", "display_name": "Malformed", "visibility": "list",
                    "supported_reasoning_levels": "low",
                ]
            ],
        ]
        for catalog in invalidCatalogs {
            server.setCatalog(catalog)
            model.retryModels()
            #expect(model.working && model.models.isEmpty && model.catalogError.isEmpty)
            #expect(!model.canSelectModel && !model.canSelectEffort && !model.canStartSession)
            model.startSession()
            try await waitUntil { !model.working }
            #expect(!model.catalogError.isEmpty && model.modelSlug.isEmpty)
            #expect(defaults.string(forKey: "chatGPTModel") == nil)
        }
        server.setCatalog([catalogModel("first", efforts: ["medium"])])
        #expect(model.recovery == .retry && model.canRecover)
        model.recover()
        try await waitUntil { !model.working }
        #expect(model.catalogError.isEmpty && model.canStartSession)
        #expect(model.modelSlug == "first" && model.reasoningEffort == "medium")
        model.authenticate()
        try await waitUntil { !model.working }
        #expect(model.account.isEmpty && model.models.isEmpty)
        #expect(!model.canSelectModel && !model.canSelectEffort && !model.canStartSession)
        model.retryModels()
        #expect(!model.working)
        await model.shutdown()
    }

    @Test func catalogQuotaKeepsUsageActionAndReloadsOnlyAfterManualRetry() async throws {
        let server = TestHTTP()
        server.setCatalog([], status: 429, code: "subscription_sharing_usage_limit_exceeded")
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let stored = StoredAccount()
        let model = Model(
            chatGPT: ChatGPT(session: session, storage: stored.storage, defaults: defaults),
            defaults: defaults)
        try await waitUntil { !model.working }
        #expect(model.recoveryTitle == "View usage" && model.canRecover && model.canRetryModels)
        #expect(model.models.isEmpty && !model.canStartSession && !model.canAnswer)
        #expect(!model.canSelectModel && !model.canSelectEffort)
        #expect(model.catalogError.contains("then choose Retry"))
        #expect(!model.catalogError.contains("Request answer") && model.error.isEmpty)
        #expect(stored.current?.session?.accessToken == "old-access")
        server.setCatalog([catalogModel("gpt-6-luna")])
        await Task.yield()
        #expect(server.modelsRequested == 1 && model.models.isEmpty)
        model.retryModels()
        #expect(model.working && !model.canRetryModels && model.catalogError.isEmpty)
        model.retryModels()
        try await waitUntil { !model.working }
        #expect(server.modelsRequested == 2 && server.wireRequests.isEmpty)
        #expect(model.catalogError.isEmpty && model.canStartSession)
        #expect(model.models.map(\.slug) == ["gpt-6-luna"])
        #expect(stored.current?.session?.accessToken == "old-access")
        await model.shutdown()
    }

    @Test func rejectedCatalogDoesNotOfferUnavailableInferenceSettings() async throws {
        let server = TestHTTP()
        server.setCatalog([], status: 400, code: "subscription_sharing_unsupported_capability")
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let model = Model(
            chatGPT: ChatGPT(
                session: session, storage: StoredAccount().storage, defaults: defaults),
            defaults: defaults)
        try await waitUntil { !model.working }
        #expect(model.recovery == .configuration && model.recoveryTitle == nil)
        #expect(model.canAuthenticate && !model.canSelectModel && !model.canSelectEffort)
        #expect(model.catalogError.contains("model catalog request"))
        #expect(model.catalogError.contains("Update Skill Issue or report"))
        #expect(!model.catalogError.contains("Choose another model"))
        #expect(!model.catalogError.contains("request an answer"))
        #expect(model.feedback?.parameter == "model")
        await Task.yield()
        #expect(server.modelsRequested == 1 && server.wireRequests.isEmpty)
        await model.shutdown()
    }

    @Test func catalogAuthorizationErrorsDoNotRequireStoppingANonexistentSession() async throws {
        for (code, status) in [
            ("subscription_sharing_invalid_user", 401),
            ("invalid_client", 400),
            ("chatpass_v2_scope_not_authorized", 403),
            ("chatpass_v2_invalid_authorization_context", 403),
            ("", 401),
        ] {
            let server = TestHTTP()
            server.setCatalog([], status: status, code: code.isEmpty ? nil : code)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let defaults = TestDefaults()
            let model = Model(
                chatGPT: ChatGPT(
                    session: session, storage: StoredAccount().storage, defaults: defaults),
                defaults: defaults)
            try await waitUntil { !model.working }
            #expect(!model.state.live && model.models.isEmpty && !model.canStartSession)
            #expect(model.canAuthenticate && !model.catalogError.isEmpty)
            #expect(!model.catalogError.contains("Stop"))
            #expect(!model.catalogError.contains("Request answer"))
            #expect(model.recovery == .configuration)
            #expect(server.modelsRequested == 1 && server.wireRequests.isEmpty)
            await model.shutdown()
        }
    }

    @Test func selectedModelAndEffortReachResponsesWithoutInventedLevels() async throws {
        let server = TestHTTP(
            output: .text,
            models: [
                catalogModel("gpt-6-luna", efforts: ["low", "high"]),
                catalogModel("plain", efforts: nil), catalogModel("unknown", efforts: ["future"]),
                catalogModel("none", efforts: ["none"]),
            ])
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(
            session: session, storage: StoredAccount().storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let models = try await chatGPT.listModels()
        for (index, effort) in ["high", "", "", "none"].enumerated() {
            try await chatGPT.prepareSession(model: models[index], effort: effort)
            try await chatGPT.answer(
                input: [], language: "English", model: models[index], effort: effort
            ) { _ in }
            let request = try #require(server.requests.last)
            #expect(request["model"] as? String == models[index].slug)
            #expect(request["store"] as? Bool == false && request["stream"] as? Bool == true)
            #expect(request["service_tier"] == nil)
            if effort.isEmpty {
                #expect(request["reasoning"] == nil)
            } else {
                #expect((request["reasoning"] as? [String: String])?["effort"] == effort)
            }
        }
        do {
            try await chatGPT.prepareSession(model: models[0], effort: "ultra")
            Issue.record("Unsupported effort was accepted")
        } catch {}
        do {
            try await chatGPT.answer(
                input: [], language: "English", model: models[0], effort: "ultra"
            ) { _ in }
            Issue.record("Unsupported effort reached the Responses endpoint")
        } catch {}
        #expect(server.requests.count == 4)
    }

    @Test func callbackStopClosesAcceptedIncompleteRequest() async throws {
        let server = try CallbackServer()
        let redirect = try #require(URL(string: try await server.start()))
        let port = try #require(redirect.port)
        let client = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        defer {
            client.cancel()
            server.stop()
        }
        let peer = CallbackPeerState()
        client.stateUpdateHandler = { state in
            Task { @MainActor in
                if case .ready = state { peer.connected = true }
            }
        }
        client.start(queue: .main)
        try await waitUntil { peer.connected }
        client.send(content: Data("GET /auth/".utf8), completion: .contentProcessed { _ in })
        // Let the server accept and begin reading this incomplete HTTP request.
        try await Task.sleep(for: .milliseconds(100))
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, complete, error in
            Task { @MainActor in
                peer.closed = complete || error != nil
            }
        }
        server.stop()
        try await waitUntil { peer.closed }
    }

    @Test func signOutWaitsForRotatingRefreshAndBlocksNewRequests() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let refresh = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        var entered = false
        let signOut = Task {
            entered = true
            _ = try await chatGPT.signOut()
        }
        try await waitUntil { entered }
        #expect(stored.events.isEmpty)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("A new request was allowed during sign out")
        } catch {}
        server.finishRefresh()
        _ = try? await refresh.value
        try await signOut.value
        #expect(stored.events == ["save:replacement-refresh", "save:signed-out"])
        #expect(server.modelsRequested == 0)
        #expect(server.revokedTokens.first?.contains("token=replacement-refresh") == true)
        #expect(stored.current?.session == nil)
        #expect(chatGPT.account?.session == nil)
    }

    @Test func shutdownKeepsConfigurationLockedUntilRotatingCredentialsAreSaved() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let client = ChatGPT(session: session, storage: stored.storage, defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await waitUntil { server.refreshPending }
        server.finishRefresh(expiresIn: 30)
        try await waitUntil { !model.working }
        try #require(model.canStartSession)
        model.state.live = true
        model.state.beginAnswer(id: "retained")
        model.state.answers[0].text = "Keep this answer while shutting down"
        model.state.answers[0].status = "complete"
        let answers = model.state.answers
        let refreshing = Task { try await client.listModels() }
        defer { refreshing.cancel() }
        try await waitUntil { server.refreshPending }
        let cleanup = model.endSession()
        var started = false
        var finished = false
        let shutdown = Task {
            started = true
            await model.shutdown()
            finished = true
        }
        try await waitUntil { started }
        #expect(model.working && model.status == "Quitting…")
        await cleanup.value
        #expect(!finished && server.refreshPending)
        #expect(model.working && model.status == "Quitting…")
        #expect(!model.canConfigureViewer && !model.canAuthenticate && !model.canChooseAccount)
        #expect(!model.canSelectModel && !model.canSelectEffort && !model.canRetryModels)
        #expect(!model.canAnswer && !model.canStartSession && !model.canRecover)
        #expect(model.state.answers == answers)
        let accessEnabled = model.viewerAccessEnabled
        model.setViewerAccessEnabled(!accessEnabled)
        model.configureViewerAccess()
        #expect(model.viewerAccessEnabled == accessEnabled && !model.configuringViewerAccess)
        server.finishRefresh(refreshToken: "shutdown-refresh")
        _ = try await refreshing.value
        await shutdown.value
        #expect(finished && stored.current?.session?.refreshToken == "shutdown-refresh")
        #expect(stored.current?.pendingSession == nil && server.refreshes == 2)
        #expect(stored.events == ["save:replacement-refresh", "save:shutdown-refresh"])
        #expect(model.state.answers == answers && !model.state.live)
        #expect(model.working && model.status == "Quitting…" && !model.canConfigureViewer)
    }

    @Test func storageFailureDoesNotReuseRevokedTokens() async throws {
        let stored = StoredAccount()
        stored.rejectSave = true
        let session = MockHTTPProtocol.session(server: TestHTTP())
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        do {
            _ = try await chatGPT.signOut()
            Issue.record("Failed storage update was accepted")
        } catch {}
        #expect(stored.current?.session != nil)
        #expect(chatGPT.account?.session == nil)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("A revoked token was reused after a Keychain failure")
        } catch {}
    }

    @Test(arguments: [false, true])
    func failedRotatedCredentialSaveStillRevokesLatestToken(_ removalFails: Bool) async throws {
        let stored = StoredAccount(expired: true)
        stored.rejectSave = true
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let refresh = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh()
        do {
            _ = try await refresh.value
            Issue.record("Failed credential write was accepted")
        } catch {}
        #expect(stored.current?.session?.refreshToken == "old-refresh")
        #expect(chatGPT.account?.session?.refreshToken == "replacement-refresh")
        stored.rejectSave = removalFails
        do {
            #expect(try await chatGPT.signOut())
            #expect(!removalFails)
        } catch let failure as ChatGPTFailure {
            #expect(removalFails && failure.recovery == .configuration)
        }
        #expect(server.revokedTokens.first?.contains("token=replacement-refresh") == true)
        #expect((stored.current?.session == nil) == !removalFails)
        #expect(chatGPT.account?.session == nil)
        #expect(server.refreshes == 1 && server.modelsRequested == 0)
    }

    @Test func failedRotatedCredentialSaveRetriesStorageWithoutRefreshingAgain() async throws {
        let stored = StoredAccount(expired: true)
        stored.rejectSave = true
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let refresh = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh()
        do {
            _ = try await refresh.value
            Issue.record("Failed credential write was accepted")
        } catch {}
        stored.rejectSave = false
        let retry = Task { try await chatGPT.listModels() }
        try await waitUntil { server.modelsRequested > 0 || server.refreshPending }
        // Complete an unexpected second refresh too, so the counter assertion
        // diagnoses stale-token reuse instead of leaving the test suspended.
        if server.refreshPending { server.finishRefresh() }
        let models = try await retry.value
        #expect(models.map(\.slug) == ["gpt-6-luna"])
        #expect(server.refreshes == 1 && server.modelsRequested == 1)
        #expect(stored.events == ["save:replacement-refresh"])
        #expect(stored.current?.session?.refreshToken == "replacement-refresh")
    }

    @Test func cancelledRefreshCredentialSaveFailureStillUpdatesModel() async throws {
        let stored = StoredAccount(expired: true)
        stored.rejectSave = true
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        let model = Model(chatGPT: chatGPT, defaults: TestDefaults())
        try await waitUntil { server.refreshPending }
        var shutdownEntered = false
        let shutdown = Task {
            shutdownEntered = true
            await model.shutdown()
        }
        try await waitUntil { shutdownEntered }
        server.finishRefresh()
        await shutdown.value
        #expect(model.recovery == .save && model.error.contains("Keychain"))
        #expect(model.account == "fake@example.invalid" && !model.canStartSession)
        #expect(chatGPT.account?.session?.refreshToken == "replacement-refresh")
        #expect(stored.current?.session?.refreshToken == "old-refresh")
        #expect(server.refreshes == 1 && server.modelsRequested == 0)
    }

    @Test(arguments: [false, true])
    func pendingCredentialSaveRecoveryKeepsContextAndPlanState(_ live: Bool) async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        let model = Model(chatGPT: chatGPT, defaults: TestDefaults())
        try await waitUntil { server.refreshPending }
        server.finishRefresh(expiresIn: 30)
        try await waitUntil { !model.working }
        model.state.live = live
        model.state.beginAnswer(id: "retained-answer")
        model.state.answers[0].text = "Retained answer"
        model.state.answers[0].status = "complete"
        let retained = model.state.answers
        stored.rejectSave = true
        let refresh = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        server.finishRefresh(scope: "openid profile email")
        do {
            _ = try await refresh.value
            Issue.record("Failed credential save was accepted")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .save) }
        #expect(model.recovery == .save && model.canRecover && model.recoveryTitle == "Retry")
        #expect(model.error.contains("Keychain") && !model.canAnswer)
        model.recover()
        #expect(model.recovery == .save && model.canRecover)
        #expect(model.state.live == live && model.state.answers == retained)
        stored.rejectSave = false
        model.recover()
        try await waitUntil { !model.working }
        #expect(model.recovery == .enablePlan && model.needsPlanPermission)
        #expect(model.canRecover && model.state.answers == retained)
        #expect(!model.state.live && !model.working && !model.canAnswer)
        #expect(stored.current?.session?.scopes == ["openid", "profile", "email"])
        #expect(server.refreshes == 2 && server.modelsRequested == 1)
        #expect(server.wireRequests.isEmpty)
        await model.shutdown()
    }

    @Test func terminalRefreshCannotBeRepeatedWhenKeychainWriteFails() async throws {
        let stored = StoredAccount(expired: true)
        stored.rejectSave = true
        let server = TestHTTP(refreshError: "invalid_grant")
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        for _ in 0..<2 {
            do {
                _ = try await chatGPT.listModels()
                Issue.record("Unusable tokens were accepted")
            } catch {}
        }
        #expect(!chatGPT.isSignedIn && chatGPT.account?.clientID == "fake-client")
        #expect(
            stored.current?.session != nil && server.refreshes == 1 && server.modelsRequested == 0)
    }

    @Test func shutdownWaitsForRotatingRefreshToReachStorage() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        let model = Model(chatGPT: chatGPT, defaults: TestDefaults())
        try await waitUntil { server.refreshPending }
        #expect(model.working && !model.canSelectModel && !model.canSelectEffort)
        #expect(!model.canStartSession && model.models.isEmpty)
        var finished = false
        let shutdown = Task {
            await model.shutdown()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished)
        #expect(stored.events.isEmpty)
        server.finishRefresh()
        await shutdown.value
        #expect(finished)
        #expect(stored.current?.session?.refreshToken == "replacement-refresh")
        #expect(stored.events == ["save:replacement-refresh"])
        #expect(server.modelsRequested == 0)
        #expect(model.models.isEmpty && !model.canStartSession)
    }

    @Test func refusalIsVisibleAndEmptyCompletionFails() async throws {
        for output in [TestHTTP.Output.text, .refusal, .empty, .whitespace] {
            let session = MockHTTPProtocol.session(server: TestHTTP(output: output))
            defer { session.invalidateAndCancel() }
            let chatGPT = ChatGPT(
                session: session, storage: StoredAccount().storage, defaults: TestDefaults())
            try await chatGPT.restore()
            let models = try await chatGPT.listModels()
            try await chatGPT.prepareSession(model: models[0], effort: "low")
            var text = ""
            var failed = false
            do {
                try await chatGPT.answer(
                    input: [], language: "English",
                    model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                ) { text += $0 }
            } catch {
                failed = true
            }
            if output == .text {
                #expect(!failed)
                #expect(text == "Use constant auxiliary space.")
            } else if output == .refusal {
                #expect(!failed)
                #expect(text == "I cannot assist with that request.")
            } else {
                #expect(failed)
            }
        }
    }

    @Test func eventStreamFramingPreservesUnicodeAndMultilineData() async throws {
        for delimiter in ["\n", "\r\n", "\r"] {
            let stream = """
                : heartbeat

                event: response.output_text.delta
                id: ignored
                data: {"type":"response.output_text.delta",
                data: "delta":"Привет 🐢"}

                data: {"type":"response.completed"}

                data: [DONE]


                """.replacingOccurrences(of: "\n", with: delimiter)
            let bytes = Array(stream.utf8)
            let split = try #require(bytes.firstIndex(of: 0xf0)) + 1
            let server = TestHTTP(stream: [Data(bytes[..<split]), Data(bytes[split...])])
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = try await configuredChatGPT(session: session)
            var text = ""
            try await chatGPT.answer(
                input: [], language: "Russian",
                model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
            ) { text += $0 }
            #expect(text == "Привет 🐢")
            let request = try #require(server.wireRequests.first)
            #expect(server.wireRequests.count == 1 && request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
            #expect(request.timeoutInterval == 180)
        }
    }

    @Test func unfinishedAndFailedEventStreamsRejectCompletionWithoutReplay() async throws {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n"
        let completion = "data: {\"type\":\"response.completed\"}"
        let streams =
            [delta, delta + completion, delta + completion + "\n"]
            + ["response.failed", "response.incomplete", "error"].map {
                delta + "data: {\"type\":\"\($0)\"}\n\n" + completion + "\n\n"
            }
        for stream in streams {
            let server = TestHTTP(stream: [Data(stream.utf8)])
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = try await configuredChatGPT(session: session)
            var text = ""
            var failed = false
            do {
                try await chatGPT.answer(
                    input: [], language: "English",
                    model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                ) { text += $0 }
            } catch {
                failed = true
            }
            #expect(failed && text == "Partial")
            #expect(server.wireRequests.count == 1)
        }
    }

    @Test func eventStreamLineLimitIsEnforcedBeforeDispatch() async throws {
        for delimiter in ["\n", "\r\n", "\r"] {
            for size in [256_000, 256_001] {
                let prefix = "data: {\"type\":\"response.output_text.delta\",\"delta\":\""
                let suffix = "\"}"
                let text = String(
                    repeating: "x",
                    count: size - prefix.utf8.count - suffix.utf8.count)
                let stream =
                    prefix + text + suffix + delimiter + delimiter
                    + "data: {\"type\":\"response.completed\"}" + delimiter + delimiter
                let server = TestHTTP(stream: [Data(stream.utf8)])
                let session = MockHTTPProtocol.session(server: server)
                defer { session.invalidateAndCancel() }
                let chatGPT = try await configuredChatGPT(session: session)
                var received = ""
                var failed = false
                do {
                    try await chatGPT.answer(
                        input: [], language: "English",
                        model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                    ) { received += $0 }
                } catch {
                    failed = true
                }
                #expect(failed == (size > 256_000))
                #expect(received == (size > 256_000 ? "" : text))
                #expect(server.wireRequests.count == 1)
            }
        }
    }

    @Test func eventStreamAcceptsManyShortCRDelimitedEvents() async throws {
        let event = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"x\"}\r\r"
        let stream =
            String(repeating: event, count: 6000) + "data: {\"type\":\"response.completed\"}\r\r"
        let server = TestHTTP(stream: [Data(stream.utf8)])
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = try await configuredChatGPT(session: session)
        var received = ""
        try await chatGPT.answer(
            input: [], language: "English",
            model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
        ) { received += $0 }
        #expect(received == String(repeating: "x", count: 6000))
        #expect(server.wireRequests.count == 1)
    }

    @Test func cancelledEventStreamStopsRequestWithoutReplay() async throws {
        for delimiter in ["\n", "\r\n", "\r"] {
            let delta =
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}"
                + delimiter + delimiter
            let server = TestHTTP(stream: [Data(delta.utf8)], finishStream: false)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = try await configuredChatGPT(session: session)
            var text = ""
            var finished = false
            var failed = false
            let answer = Task {
                defer { finished = true }
                do {
                    try await chatGPT.answer(
                        input: [], language: "English",
                        model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                    ) { text += $0 }
                } catch {
                    failed = true
                }
            }
            defer { answer.cancel() }
            try await waitUntil { text == "Partial" }
            answer.cancel()
            try await waitUntil { finished && server.cancelledResponses > 0 }
            await answer.value
            #expect(failed && text == "Partial")
            #expect(server.wireRequests.count == 1)
        }
    }

    @Test func nonSuccessfulResponsesStatusDoesNotEmitTextOrReplay() async throws {
        let server = TestHTTP(
            stream: [
                Data(
                    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Forbidden\"}\n\n"
                        .utf8)
            ],
            responseStatus: 429)
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = try await configuredChatGPT(session: session)
        var text = ""
        var failed = false
        do {
            try await chatGPT.answer(
                input: [], language: "English",
                model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
            ) { text += $0 }
        } catch {
            failed = true
        }
        #expect(failed && text.isEmpty)
        #expect(server.wireRequests.count == 1)
    }

    @Test func droppedErrorBodyPreservesReceivedStatusDiagnosticsAndBytes() async throws {
        for body in [
            Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8),
            Data(#"{"error":{"code":"subscription_sharing_usage_"#.utf8), Data(),
        ] {
            let server = TestHTTP(
                stream: [body], responseStatus: 429, responseStreamFailure: true)
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let chatGPT = try await configuredChatGPT(session: session)
            do {
                try await chatGPT.answer(
                    input: [], language: "English",
                    model: try ChatGPTModel(fields: catalogModel("gpt-6-luna")), effort: "low"
                ) { _ in }
                Issue.record("Dropped HTTP error body was accepted")
            } catch let failure as ChatGPTFailure {
                #expect(failure.status == 429 && failure.requestID == "fixture-request")
                #expect(failure.responseBody == body)
                if body.last == UInt8(ascii: "}") {
                    #expect(failure.code == "subscription_sharing_usage_limit_exceeded")
                    #expect(failure.recovery == .usage)
                } else {
                    #expect(failure.code == nil)
                }
            }
        }
    }

    @Test func terminalRefreshAfterStopUpdatesModelWithoutInitiator() async throws {
        let store = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let client = ChatGPT(session: session, storage: store.storage, defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await waitUntil { server.refreshPending }
        server.finishRefresh(expiresIn: 1)
        try await waitUntil { !model.working }
        try #require(model.canStartSession)
        model.state.live = true
        model.state.beginAnswer(id: "saved")
        model.state.answers[0].text = "Keep this answer"
        model.state.answers[0].status = "complete"
        let pending = Task { try await client.listModels() }
        try await waitUntil { server.refreshPending }
        model.stopSession()
        pending.cancel()
        try await waitUntil { !model.working }
        server.rejectPendingRefresh()
        await client.finishPendingRefresh()
        _ = try? await pending.value
        #expect(model.account.isEmpty && model.models.isEmpty)
        #expect(model.recovery == .signIn && model.canRecover)
        #expect(model.feedback?.code == "invalid_grant")
        #expect(model.state.answers[0].text == "Keep this answer")
        #expect(!model.state.canAnswer && store.current?.session == nil)
        await model.shutdown()
    }

    @Test func cancelledReducedPermissionRefreshStillStopsTheLiveSession() async throws {
        let store = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let client = ChatGPT(session: session, storage: store.storage, defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await waitUntil { server.refreshPending }
        server.finishRefresh(expiresIn: 30)
        try await waitUntil { !model.working }
        try #require(model.canStartSession)
        model.state.live = true
        model.state.beginAnswer(id: "saved")
        model.state.answers[0].text = "Keep this answer"
        model.state.answers[0].status = "complete"
        let retained = model.state.answers
        let request = Task {
            do { _ = try await client.listModels() } catch {
                // A cancelled answer suppresses errors from its obsolete request.
                if !Task.isCancelled { model.showError(error) }
            }
        }
        try await waitUntil { server.refreshPending }
        request.cancel()
        server.finishRefresh(scope: "openid profile email")
        await request.value
        await client.finishPendingRefresh()
        try await waitUntil { !model.working }
        #expect(!model.state.live && !model.canAnswer && model.state.answers == retained)
        #expect(model.needsPlanPermission && model.models.isEmpty)
        #expect(model.recovery == .enablePlan && model.canRecover && model.canAuthenticate)
        #expect(!model.error.isEmpty && model.feedback?.stopsSession == true)
        #expect(store.current?.session?.scopes == ["openid", "profile", "email"])
        #expect(server.refreshes == 2 && server.modelsRequested == 1)
        await model.shutdown()
    }

    @Test func cancelledRefreshAuthorizationFailuresStillStopTheLiveSession() async throws {
        for (code, status, terminal) in [
            ("invalid_client", 400, true),
            ("subscription_sharing_invalid_user", 401, true),
            ("subscription_sharing_user_not_eligible", 403, true),
            ("chatpass_v2_scope_not_authorized", 403, true),
            ("chatpass_v2_invalid_authorization_context", 403, true),
            (nil, 401, true),
            ("temporarily_unavailable", 503, false),
        ] as [(String?, Int, Bool)] {
            let store = StoredAccount(expired: true)
            let server = TestHTTP()
            let session = MockHTTPProtocol.session(server: server)
            defer { session.invalidateAndCancel() }
            let defaults = TestDefaults()
            let client = ChatGPT(session: session, storage: store.storage, defaults: defaults)
            let model = Model(chatGPT: client, defaults: defaults)
            try await waitUntil { server.refreshPending }
            server.finishRefresh(expiresIn: 30)
            try await waitUntil { !model.working }
            try #require(model.canStartSession)
            model.state.live = true
            model.state.beginAnswer(id: "saved")
            model.state.answers[0].text = "Keep this answer"
            model.state.answers[0].status = "complete"
            let retained = model.state.answers
            let request = Task {
                do { _ = try await client.listModels() } catch {
                    if !Task.isCancelled { model.showError(error) }
                }
            }
            try await waitUntil { server.refreshPending }
            request.cancel()
            server.rejectPendingRefresh(code: code, status: status)
            await request.value
            await client.finishPendingRefresh()
            try await waitUntil { !model.working }
            #expect(model.state.live == !terminal)
            #expect(model.canAnswer == !terminal)
            #expect(model.state.answers == retained)
            // Registration failures are not evidence that a refresh token was revoked.
            #expect(store.current?.session?.refreshToken == "replacement-refresh")
            #expect(model.savedAccounts.count == 1 && !model.account.isEmpty)
            if terminal {
                #expect(model.feedback?.status == status && model.feedback?.code == code)
                #expect(model.feedback?.requestID == "fixture-request")
                #expect(!model.error.isEmpty && model.canAuthenticate)
                #expect(
                    model.recovery
                        == (code == "subscription_sharing_user_not_eligible"
                            ? .none : .configuration))
                #expect(!model.canRecover)
            } else {
                #expect(model.feedback == nil && model.error.isEmpty)
            }
            #expect(server.refreshes == 2 && server.modelsRequested == 1)
            #expect(server.wireRequests.isEmpty)
            await model.shutdown()
        }
    }

    @Test func terminalRefreshWhileLiveStopsWithoutDiscardingAnswers() async throws {
        let store = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let client = ChatGPT(session: session, storage: store.storage, defaults: defaults)
        let model = Model(chatGPT: client, defaults: defaults)
        try await waitUntil { server.refreshPending }
        server.finishRefresh(expiresIn: 30)
        try await waitUntil { !model.working }
        try #require(model.canStartSession)
        model.state.live = true
        model.state.beginAnswer(id: "saved")
        model.state.answers[0].text = "Keep this answer"
        model.state.answers[0].status = "complete"
        let retained = model.state.answers
        let request = Task { try await client.listModels() }
        try await waitUntil { server.refreshPending }
        server.rejectPendingRefresh()
        await client.finishPendingRefresh()
        do {
            _ = try await request.value
            Issue.record("A revoked refresh token was accepted")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .signIn) }
        try await waitUntil { !model.working }
        #expect(!model.state.live && !model.canAnswer && model.state.answers == retained)
        #expect(model.account.isEmpty && model.models.isEmpty)
        #expect(model.canAuthenticate && model.canConfigureViewer)
        #expect(model.recovery == .signIn && model.canRecover)
        #expect(model.feedback?.code == "invalid_grant" && !model.error.isEmpty)
        #expect(store.current?.session == nil && store.current?.clientID == "fake-client")
        #expect(server.refreshes == 2 && server.modelsRequested == 1 && server.wireRequests.isEmpty)
        await model.shutdown()
    }

    @Test func terminalRefreshNotifiesAccountStateAfterInitiatorCancellation() async throws {
        let stored = StoredAccount(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        var notifications: [ChatGPTFailure?] = []
        chatGPT.accountStateChanged = { notifications.append($0) }
        let request = Task { try await chatGPT.listModels() }
        try await waitUntil { server.refreshPending }
        request.cancel()
        server.rejectPendingRefresh()
        do {
            _ = try await request.value
            Issue.record("Invalid refresh was accepted")
        } catch {}
        #expect(!chatGPT.isSignedIn && stored.current?.session == nil)
        #expect(chatGPT.registrations.count == 1)
        #expect(notifications.count == 1 && notifications[0]?.recovery == .signIn)
        #expect(notifications[0]?.code == "invalid_grant")
        #expect(notifications[0]?.requestID == "fixture-request")
    }

    @Test func droppedCatalogErrorPreservesStatusCodeAndDiagnostics() async throws {
        let body = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8)
        let server = TestHTTP(droppedJSONError: ("/v1/models", body, 429))
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(
            session: session, storage: StoredAccount().storage, defaults: TestDefaults())
        try await chatGPT.restore()
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Dropped catalog error was accepted")
        } catch let failure as ChatGPTFailure {
            #expect(failure.status == 429 && failure.requestID == "fixture-request")
            #expect(failure.code == "subscription_sharing_usage_limit_exceeded")
            #expect(failure.responseBody == body && failure.recovery == .usage)
        }
    }

    @Test func droppedTerminalRefreshErrorStillClearsSessionAndRetainsDiagnostics() async throws {
        let body = Data(#"{"error":"invalid_grant"}"#.utf8)
        let stored = StoredAccount(expired: true)
        let server = TestHTTP(droppedJSONError: ("/api/accounts/oauth/token", body, 400))
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        var change: ChatGPTFailure?
        chatGPT.accountStateChanged = { change = $0 }
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Dropped terminal refresh error was accepted")
        } catch let failure as ChatGPTFailure {
            #expect(failure.status == 400 && failure.code == "invalid_grant")
            #expect(failure.requestID == "fixture-request" && failure.responseBody == body)
        }
        #expect(!chatGPT.isSignedIn && stored.current?.session == nil)
        #expect(chatGPT.registrations.count == 1)
        #expect(change?.code == "invalid_grant" && change?.requestID == "fixture-request")
    }

}
