import Foundation
import JOSESwift
import Security
import Testing

@testable import SkillIssue

private final class OAuthFixture: @unchecked Sendable {
    enum InvalidIdentity: Sendable {
        case subject, nonce, callbackClient, emptyClient, audience, expired
    }
    private let lock = NSLock()
    private let signingKey: SecKey
    private let publicKey: RSAPublicKey
    private var stored: ChatGPTAccounts?
    private var loadUnavailable = false
    private var saveUnavailable = false
    private var requests: [[String: String]] = []
    private var exchanges: [[String: String]] = []
    private var models = 0
    private var jwksUnavailable = false
    private var heldIdentityPath: String?
    private var heldIdentityResponse: OAuthHTTP?
    private var refreshCount = 0
    private var refreshIncludesIdentity = true
    private var revocations: [[String: String]] = []
    private let expiresIn: Int
    private var refreshExpiresIn: Int
    private var identityOnly = false
    private var codeExchangeRejected = false
    private var invalidIdentity: InvalidIdentity?
    private var issuedClient = "test-client"
    private var subject = "test-subject"
    private var callbackTask: Task<Void, Error>?
    let defaults = TestDefaults()

    init(identityOnly: Bool = false, expiresIn: Int = 3600, refreshExpiresIn: Int = 3600) throws {
        var error: Unmanaged<CFError>?
        signingKey = try #require(
            SecKeyCreateRandomKey(
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary,
                &error))
        publicKey = try RSAPublicKey(
            publicKey: #require(SecKeyCopyPublicKey(signingKey)),
            additionalParameters: ["kid": "test-signing-key"])
        self.identityOnly = identityOnly
        self.expiresIn = expiresIn
        self.refreshExpiresIn = refreshExpiresIn
    }

    var account: ChatGPTAccount? { lock.withLock { stored?.selected } }
    var registrations: [ChatGPTAccount] { lock.withLock { stored?.accounts ?? [] } }
    var authorizations: [[String: String]] { lock.withLock { requests } }
    var tokenRequests: [[String: String]] { lock.withLock { exchanges } }
    var modelRequests: Int { lock.withLock { models } }
    var revocationRequests: [[String: String]] { lock.withLock { revocations } }
    var storage: AccountStorage {
        AccountStorage(
            load: { [self] in
                try lock.withLock {
                    if loadUnavailable { throw AppFailure.failed }
                    return stored
                }
            },
            save: { [self] account in
                try lock.withLock {
                    if saveUnavailable { throw AppFailure.failed }
                    stored = try JSONDecoder().decode(
                        ChatGPTAccounts.self, from: JSONEncoder().encode(account))
                }
            })
    }
    func setLoadUnavailable(_ unavailable: Bool) { lock.withLock { loadUnavailable = unavailable } }
    func setSaveUnavailable(_ unavailable: Bool) { lock.withLock { saveUnavailable = unavailable } }
    func setJWKSUnavailable(_ unavailable: Bool) { lock.withLock { jwksUnavailable = unavailable } }
    func setRefreshIdentityIncluded(_ included: Bool) {
        lock.withLock { refreshIncludesIdentity = included }
    }
    func setRefreshExpiry(_ seconds: Int) { lock.withLock { refreshExpiresIn = seconds } }
    func holdIdentityRequest(at path: String) { lock.withLock { heldIdentityPath = path } }
    var identityRequestPending: Bool { lock.withLock { heldIdentityResponse != nil } }
    func hold(_ response: OAuthHTTP) -> Bool {
        lock.withLock {
            guard let path = heldIdentityPath, path == response.request.url?.path else {
                return false
            }
            heldIdentityPath = nil
            heldIdentityResponse = response
            return true
        }
    }
    func finishIdentityRequest(status: Int) {
        let response = lock.withLock {
            let response = heldIdentityResponse
            heldIdentityResponse = nil
            return response
        }
        response?.respond(status: status, body: Data())
    }
    func expirePendingGrant(identity: Bool) throws {
        try lock.withLock {
            var value = try #require(stored)
            let index = try #require(
                value.accounts.firstIndex { $0.clientID == value.selectedClientID })
            var pending = try #require(value.accounts[index].pendingSession)
            pending.expires = Date().addingTimeInterval(-60)
            if identity {
                let token = try JWS(compactSerialization: pending.idToken)
                var claims = try #require(
                    JSONSerialization.jsonObject(with: token.payload.data()) as? [String: Any])
                claims["iat"] = Date().addingTimeInterval(-7200).timeIntervalSince1970
                claims["exp"] = Date().addingTimeInterval(-60).timeIntervalSince1970
                pending.idToken = try signedIdentity(claims)
            }
            value.accounts[index].pendingSession = pending
            stored = value
        }
    }
    func allowPlan() { lock.withLock { identityOnly = false } }
    func rejectCodeExchange(_ rejected: Bool) { lock.withLock { codeExchangeRejected = rejected } }
    func useIdentity(client: String, subject: String) {
        lock.withLock {
            issuedClient = client
            self.subject = subject
        }
    }
    func invalidate(_ value: InvalidIdentity?) { lock.withLock { invalidIdentity = value } }
    func cleanUp() {
        finishIdentityRequest(status: 503)
    }

    func open(_ url: URL) -> Bool {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let parameters = fields(query), let redirect = parameters["redirect_uri"],
            var callback = URLComponents(string: redirect), callback.scheme == "http",
            callback.host == "127.0.0.1", callback.path == "/auth/callback",
            let state = parameters["state"]
        else { return false }
        let (invalid, issuedClient, attempt) = lock.withLock {
            requests.append(parameters)
            return (invalidIdentity, issuedClient, requests.count)
        }
        callback.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "test-code-\(attempt)"),
        ]
        if parameters["client_id"] == "dynamic_agent_client" || invalid == .callbackClient {
            callback.queryItems?.append(
                URLQueryItem(
                    name: "client_id",
                    value: invalid == .emptyClient
                        ? "" : invalid == .callbackClient ? "other-client" : issuedClient))
        }
        guard let callbackURL = callback.url else { return false }
        let task = Task {
            var request = URLRequest(url: callbackURL)
            request.timeoutInterval = 3
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
        }
        lock.withLock { callbackTask = task }
        return true
    }

    func finishCallback() async throws {
        let task = lock.withLock { callbackTask }
        try await task?.value
    }

    private func fields(_ query: [URLQueryItem]) -> [String: String]? {
        var values: [String: String] = [:]
        for item in query {
            guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                return nil
            }
        }
        return values
    }

    private func signedIdentity(_ claims: [String: Any]) throws -> String {
        var header = JWSHeader(algorithm: .RS256)
        header.kid = "test-signing-key"
        let signer = try #require(Signer(signatureAlgorithm: .RS256, key: signingKey))
        return try JWS(
            header: header, payload: Payload(JSONSerialization.data(withJSONObject: claims)),
            signer: signer
        ).compactSerializedString
    }

    func response(to request: URLRequest) throws -> (Int, Data) {
        let body: [String: Any]
        switch request.url?.path {
        case "/.well-known/openid-configuration":
            body = [
                "issuer": "https://auth.openai.com",
                "jwks_uri": "https://auth.openai.com/test-jwks",
                "revocation_endpoint": "https://auth.openai.com/test-revoke",
            ]
        case "/test-jwks":
            if lock.withLock({ jwksUnavailable }) {
                return (503, Data(#"{"error":{"code":"temporarily_unavailable"}}"#.utf8))
            }
            body = ["keys": [publicKey.parameters]]
        case "/test-revoke":
            let text = try #require(String(data: requestBody(request), encoding: .utf8))
            let fields = try #require(
                fields(URLComponents(string: "https://example.invalid/?\(text)")?.queryItems ?? []))
            lock.withLock { revocations.append(fields) }
            return (200, Data())
        case "/v1/models":
            lock.withLock { models += 1 }
            body = [
                "models": [
                    [
                        "slug": "gpt-6-luna", "display_name": "GPT-6 Luna", "visibility": "list",
                        "supported_reasoning_levels": [["effort": "low"]],
                    ]
                ]
            ]
        case "/api/accounts/oauth/token":
            let text = try #require(String(data: requestBody(request), encoding: .utf8))
            let exchange = try #require(
                fields(URLComponents(string: "https://example.invalid/?\(text)")?.queryItems ?? []))
            let values = lock.withLock { () -> ([String: String], Bool, InvalidIdentity?, String) in
                exchanges.append(exchange)
                return (requests.last ?? [:], identityOnly, invalidIdentity, subject)
            }
            let refreshing = exchange["grant_type"] == "refresh_token"
            let rotation: Int
            if refreshing {
                let next = lock.withLock { () -> Int? in
                    let expected =
                        refreshCount == 0
                        ? "test-refresh"
                        : refreshCount == 1
                            ? "replacement-refresh"
                            : "replacement-refresh-\(refreshCount)"
                    guard exchange["refresh_token"] == expected else { return nil }
                    refreshCount += 1
                    return refreshCount
                }
                guard let next else {
                    return (400, Data(#"{"error":"refresh_token_reused"}"#.utf8))
                }
                rotation = next
            } else {
                lock.withLock { refreshCount = 0 }
                rotation = 0
            }
            if lock.withLock({ codeExchangeRejected }) {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            let claims: [String: Any] = [
                "iss": "https://auth.openai.com",
                "aud": values.2 == .audience ? "other-client" : exchange["client_id"]!,
                "sub": values.2 == .subject ? "other-subject" : values.3,
                "email": "test@example.invalid",
                "jti": refreshing ? "rotated-identity" : "signed-in-identity",
                "nonce": values.2 == .nonce ? "other-nonce" : values.0["nonce"]!,
                "iat": Date().timeIntervalSince1970,
                "exp": Date().addingTimeInterval(values.2 == .expired ? -60 : 3600)
                    .timeIntervalSince1970,
            ]
            let token = try signedIdentity(claims)
            if values.1 {
                body = ["id_token": token, "scope": "openid profile email"]
            } else {
                var grant: [String: Any] = [
                    "id_token": token,
                    "access_token":
                        !refreshing
                        ? "test-access"
                        : rotation == 1 ? "replacement-access" : "replacement-access-\(rotation)",
                    "refresh_token":
                        !refreshing
                        ? "test-refresh"
                        : rotation == 1 ? "replacement-refresh" : "replacement-refresh-\(rotation)",
                    "token_type": "Bearer",
                    "expires_in": refreshing ? lock.withLock { refreshExpiresIn } : expiresIn,
                    "scope":
                        "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                ]
                if refreshing && !lock.withLock({ refreshIncludesIdentity }) {
                    grant.removeValue(forKey: "id_token")
                }
                body = grant
            }
        default:
            Issue.record("Unexpected OAuth request: \(request.url?.path ?? "nil")")
            return (404, Data())
        }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }
}

private final class OAuthRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture: OAuthFixture?
    func use(_ value: OAuthFixture?) { lock.withLock { fixture = value } }
    func response(to request: URLRequest) throws -> (Int, Data) {
        let current = try #require(lock.withLock { fixture })
        return try current.response(to: request)
    }
    func hold(_ response: OAuthHTTP) throws -> Bool {
        let current = try #require(lock.withLock { fixture })
        return current.hold(response)
    }
}

private final class OAuthHTTP: URLProtocol, @unchecked Sendable {
    static let route = OAuthRoute()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            if try Self.route.hold(self) { return }
            let (status, body) = try Self.route.response(to: request)
            respond(status: status, body: body)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func respond(status: Int, body: Data) {
        do {
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json", "x-request-id": "oauth-test-request",
                    ]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct OAuthTests {
    private func session(_ fixture: OAuthFixture) -> URLSession {
        OAuthHTTP.route.use(fixture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthHTTP.self]
        return URLSession(configuration: config)
    }

    @Test(arguments: [false, true], [false, true])
    func rotatedGrantSurvivesIdentityVerificationOutageWithoutRepeatingRefresh(
        _ cancelledCaller: Bool, _ restarted: Bool
    ) async throws {
        let fixture = try OAuthFixture(expiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        let original = try #require(chatGPT.account?.session)
        fixture.setJWKSUnavailable(true)
        let pending = Task { try await chatGPT.listModels() }
        if cancelledCaller { pending.cancel() }
        do {
            _ = try await pending.value
            Issue.record("An unverified refreshed identity allowed model access")
        } catch let failure as ChatGPTFailure {
            #expect(failure.status == 503 && failure.recovery == .retry)
        }
        #expect(fixture.modelRequests == 0)
        #expect(chatGPT.account?.subject == "test-subject")
        #expect(chatGPT.account?.session?.accessToken == original.accessToken)
        #expect(chatGPT.account?.session?.idToken == original.idToken)
        #expect(fixture.account?.pendingSession?.refreshToken == "replacement-refresh")
        #expect(fixture.account?.session?.idToken == original.idToken)
        fixture.setJWKSUnavailable(false)
        let retrying: ChatGPT
        if restarted {
            retrying = ChatGPT(
                session: http, storage: fixture.storage, defaults: fixture.defaults,
                openAuthorization: fixture.open)
            try await retrying.restore()
        } else {
            retrying = chatGPT
        }
        let models = try await retrying.listModels()
        #expect(models.map(\.slug) == ["gpt-6-luna"])
        #expect(fixture.tokenRequests.filter { $0["grant_type"] == "refresh_token" }.count == 1)
        #expect(retrying.account?.session?.refreshToken == "replacement-refresh")
        #expect(fixture.account?.session?.refreshToken == "replacement-refresh")
        #expect(retrying.account?.session?.idToken != original.idToken)
        #expect(fixture.account?.pendingSession == nil)
    }

    @Test(arguments: ["/.well-known/openid-configuration", "/test-jwks"], [401, 503])
    func cancelledIdentityFailureKeepsRotationAndStopsOnlyForTerminalAuthorization(
        _ path: String, _ status: Int
    ) async throws {
        for restarted in [false, true] {
            let fixture = try OAuthFixture(expiresIn: 1, refreshExpiresIn: 30)
            let http = session(fixture)
            defer {
                http.invalidateAndCancel()
                OAuthHTTP.route.use(nil)
                fixture.cleanUp()
            }
            let signedIn = ChatGPT(
                session: http, storage: fixture.storage, defaults: fixture.defaults,
                openAuthorization: fixture.open)
            try await signedIn.restore()
            try await signedIn.signIn()
            try await fixture.finishCallback()
            fixture.setRefreshIdentityIncluded(false)
            let client = ChatGPT(
                session: http, storage: fixture.storage, defaults: fixture.defaults,
                openAuthorization: fixture.open)
            let model = Model(chatGPT: client, defaults: fixture.defaults)
            try await loaded(model)
            try #require(model.canStartSession && fixture.modelRequests == 1)
            model.state.live = true
            model.state.beginAnswer(id: "retained", language: "English")
            model.state.answers[0].text = "Keep this received answer"
            model.state.answers[0].status = "complete"
            let answers = model.state.answers
            let previousIdentity = try #require(client.account?.session?.idToken)
            fixture.setRefreshIdentityIncluded(true)
            fixture.setRefreshExpiry(3600)
            fixture.holdIdentityRequest(at: path)
            let request = Task {
                do { _ = try await client.listModels() } catch {
                    if !Task.isCancelled { model.showError(error) }
                }
            }
            defer { request.cancel() }
            let deadline = ContinuousClock.now + .seconds(3)
            while !fixture.identityRequestPending, ContinuousClock.now < deadline {
                await Task.yield()
            }
            try #require(fixture.identityRequestPending)
            try #require(
                fixture.account?.pendingSession?.refreshToken == "replacement-refresh-2")
            request.cancel()
            fixture.finishIdentityRequest(status: status)
            await request.value
            await client.finishPendingRefresh()
            try await loaded(model)
            let terminal = status == 401
            #expect(model.state.live == !terminal && model.canAnswer == !terminal)
            #expect(model.state.answers == answers && model.account == "test@example.invalid")
            #expect(model.canAuthenticate == terminal && model.canConfigureViewer == terminal)
            #expect(fixture.registrations.map(\.subject) == ["test-subject"])
            #expect(fixture.account?.session?.idToken == previousIdentity)
            #expect(fixture.account?.session?.refreshToken == "replacement-refresh")
            #expect(fixture.account?.pendingSession?.refreshToken == "replacement-refresh-2")
            if terminal {
                #expect(model.feedback?.status == 401 && model.feedback?.stopsSession == true)
                #expect(model.feedback?.requestID == "oauth-test-request")
                #expect(!model.error.isEmpty)
            } else {
                #expect(model.feedback == nil && model.error.isEmpty)
            }
            let refreshes = fixture.tokenRequests.filter { $0["grant_type"] == "refresh_token" }
            #expect(
                refreshes.map { $0["refresh_token"] } == ["test-refresh", "replacement-refresh"])
            #expect(fixture.modelRequests == 1)
            let retrying: ChatGPT
            if restarted {
                retrying = ChatGPT(
                    session: http, storage: fixture.storage, defaults: fixture.defaults,
                    openAuthorization: fixture.open)
                try await retrying.restore()
            } else {
                retrying = client
            }
            let models = try await retrying.listModels()
            #expect(models.map(\.slug) == ["gpt-6-luna"])
            #expect(fixture.modelRequests == 2 && fixture.tokenRequests.count == 3)
            #expect(retrying.account?.session?.refreshToken == "replacement-refresh-2")
            #expect(fixture.account?.pendingSession == nil)
            #expect(fixture.account?.session?.refreshToken == "replacement-refresh-2")
            #expect(model.state.answers == answers)
            await model.shutdown()
        }
    }

    @Test(arguments: [false, true], [false, true])
    func expiredPendingGrantRefreshesTheLatestTokenBeforeAccess(
        _ expiredIdentity: Bool, _ replacementIdentity: Bool
    )
        async throws
    {
        let fixture = try OAuthFixture(expiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        fixture.setJWKSUnavailable(true)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Unavailable identity verification appeared successful")
        } catch let failure as ChatGPTFailure { #expect(failure.status == 503) }
        #expect(fixture.modelRequests == 0)
        try fixture.expirePendingGrant(identity: expiredIdentity)
        if !replacementIdentity { fixture.setRefreshIdentityIncluded(false) }
        fixture.setJWKSUnavailable(false)
        let restored = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await restored.restore()
        if expiredIdentity && !replacementIdentity {
            for _ in 0..<2 {
                do {
                    _ = try await restored.listModels()
                    Issue.record("An expired unverified identity allowed model access")
                } catch let failure as ChatGPTFailure { #expect(failure.recovery == .signIn) }
            }
            #expect(fixture.modelRequests == 0)
            #expect(fixture.account?.pendingSession?.expires.map { $0 > Date() } == true)
            #expect(try await restored.signOut())
            #expect(fixture.revocationRequests.map { $0["token"] } == ["replacement-refresh-2"])
            #expect(!restored.isSignedIn && fixture.account?.pendingSession == nil)
        } else {
            let models = try await restored.listModels()
            #expect(models.map(\.slug) == ["gpt-6-luna"])
            #expect(fixture.modelRequests == 1)
            #expect(restored.account?.session?.expires.map { $0 > Date() } == true)
            #expect(restored.account?.session?.refreshToken == "replacement-refresh-2")
        }
        let refreshes = fixture.tokenRequests.filter { $0["grant_type"] == "refresh_token" }
        #expect(refreshes.map { $0["refresh_token"] } == ["test-refresh", "replacement-refresh"])
        #expect(restored.account?.subject == "test-subject")
        #expect(fixture.account?.pendingSession == nil)
    }

    @Test func signInRequirementSurvivesUnrelatedFailureUntilVerifiedAuthentication() async throws {
        let fixture = try OAuthFixture(expiresIn: 1, refreshExpiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        let model = Model(chatGPT: chatGPT, defaults: fixture.defaults)
        try await loaded(model)
        #expect(model.canStartSession && fixture.modelRequests == 1)
        model.state.live = true
        model.state.beginAnswer(id: "saved-answer", language: "English")
        model.state.answers[0].text = "A useful existing answer"
        model.state.answers[0].status = "complete"
        let answers = model.state.answers
        fixture.invalidate(.expired)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Expired identity allowed model access")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .signIn) }
        #expect(chatGPT.requiresSignIn && chatGPT.isSignedIn && chatGPT.canUsePlan)
        #expect(model.recovery == .signIn && !model.canRecover)
        #expect(!model.canAnswer && !model.state.canAnswer && !model.models.isEmpty)
        #expect(fixture.account?.pendingSession?.refreshToken == "replacement-refresh-2")
        await model.endSession(failed: true, error: AppFailure.failed).value
        #expect(model.feedback == nil && !model.error.isEmpty)
        #expect(model.status == "Sign in required" && model.recovery == .signIn && model.canRecover)
        #expect(!model.canAnswer && !model.state.canAnswer && !model.canStartSession)
        #expect(!model.canRetryModels && model.state.answers == answers)
        #expect(fixture.modelRequests == 1)
        fixture.invalidate(nil)
        model.recover()
        try await loaded(model)
        try await fixture.finishCallback()
        #expect(!chatGPT.requiresSignIn && model.canStartSession && model.error.isEmpty)
        #expect(model.state.answers == answers && fixture.modelRequests == 2)
        await model.shutdown()
    }

    @Test(arguments: [OAuthFixture.InvalidIdentity.subject, .audience])
    private func refreshedIdentityCannotChangeVerifiedAccountOrAllowModelAccess(
        _ invalid: OAuthFixture.InvalidIdentity
    ) async throws {
        let fixture = try OAuthFixture(expiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        let original = try #require(chatGPT.account?.session)
        fixture.invalidate(invalid)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("An invalid refreshed identity allowed model access")
        } catch {
            #expect(fixture.modelRequests == 0)
            #expect(chatGPT.account?.subject == "test-subject")
            if invalid == .subject {
                #expect((error as? ChatGPTFailure)?.recovery == .signIn)
                #expect(chatGPT.account?.session == nil && chatGPT.account?.pendingSession == nil)
                #expect(fixture.account?.session == nil && fixture.account?.pendingSession == nil)
            } else {
                #expect(chatGPT.account?.session?.idToken == original.idToken)
                #expect(chatGPT.account?.session?.accessToken == original.accessToken)
                #expect(fixture.account?.session?.refreshToken == original.refreshToken)
            }
        }
        #expect(try await chatGPT.signOut())
        #expect(
            fixture.revocationRequests.map { $0["token"] }
                == (invalid == .subject ? [] : ["replacement-refresh"]))
        #expect(chatGPT.registrations.map(\.subject) == ["test-subject"])
    }

    @Test func refreshedSubjectMismatchStopsLiveAndCannotReuseTheGrantAfterRestart() async throws {
        let fixture = try OAuthFixture(expiresIn: 1, refreshExpiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let client = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await client.restore()
        try await client.signIn()
        try await fixture.finishCallback()
        let model = Model(chatGPT: client, defaults: fixture.defaults)
        try await loaded(model)
        try #require(model.canStartSession)
        model.state.live = true
        model.state.beginAnswer(id: "retained", language: "English")
        model.state.answers[0].text = "Keep this received answer"
        model.state.answers[0].status = "complete"
        let answers = model.state.answers
        fixture.invalidate(.subject)
        do {
            _ = try await client.listModels()
            Issue.record("A refreshed identity for another account was accepted")
        } catch {}
        try await loaded(model)
        #expect(!model.state.live && !model.canAnswer && model.state.answers == answers)
        #expect(model.account.isEmpty && client.account?.session == nil)
        #expect(model.recovery == .signIn && model.canRecover && model.canAuthenticate)
        #expect(fixture.account?.session == nil && fixture.account?.pendingSession == nil)
        #expect(fixture.registrations.map(\.subject) == ["test-subject"])
        let exchanges = fixture.tokenRequests.count
        let restarted = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await restarted.restore()
        do {
            _ = try await restarted.listModels()
            Issue.record("A rejected refreshed identity was reused after restart")
        } catch let failure as ChatGPTFailure {
            #expect(failure.recovery == .signIn)
        } catch { Issue.record("Rejected credentials did not offer sign-in after restart") }
        #expect(fixture.tokenRequests.count == exchanges && fixture.modelRequests == 1)
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func signOutRevokesRotatedGrantEvenWhenIdentityVerificationIsUnavailable(
        _ restarted: Bool
    ) async throws {
        let fixture = try OAuthFixture(expiresIn: 1)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        fixture.setJWKSUnavailable(true)
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Unavailable identity verification appeared successful")
        } catch let failure as ChatGPTFailure { #expect(failure.status == 503) }
        let signingOut: ChatGPT
        if restarted {
            signingOut = ChatGPT(
                session: http, storage: fixture.storage, defaults: fixture.defaults,
                openAuthorization: fixture.open)
            try await signingOut.restore()
        } else {
            signingOut = chatGPT
        }
        #expect(try await signingOut.signOut())
        #expect(fixture.revocationRequests.map { $0["token"] } == ["replacement-refresh"])
        #expect(fixture.revocationRequests.map { $0["client_id"] } == ["test-client"])
        #expect(!signingOut.isSignedIn && fixture.account?.session == nil)
        #expect(fixture.account?.pendingSession == nil)
        #expect(signingOut.registrations.map(\.subject) == ["test-subject"])
        #expect(fixture.tokenRequests.filter { $0["grant_type"] == "refresh_token" }.count == 1)
    }

    @Test func identityOnlySignInCanExplicitlyEnablePlanWithSameRegistration() async throws {
        let fixture = try OAuthFixture(identityOnly: true)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        #expect(chatGPT.isSignedIn && !chatGPT.canUsePlan)
        #expect(
            chatGPT.account?.clientID == "test-client" && chatGPT.account?.subject == "test-subject"
        )
        do {
            _ = try await chatGPT.listModels()
            Issue.record("Identity-only sign-in allowed model access")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .enablePlan) }
        #expect(fixture.modelRequests == 0)
        #expect(fixture.authorizations[0]["client_id"] == "dynamic_agent_client")
        #expect(fixture.authorizations[0]["agent_name_hint"] == "Skill Issue")
        #expect(fixture.authorizations[0]["prompt"] == nil)
        fixture.allowPlan()
        try await chatGPT.signIn(requestPlanConsent: true)
        try await fixture.finishCallback()
        #expect(chatGPT.canUsePlan && fixture.account?.session?.refreshToken == "test-refresh")
        let request = fixture.authorizations[1]
        #expect(request["client_id"] == "test-client" && request["prompt"] == "consent")
        #expect(request["agent_name_hint"] == nil && request["force_reconsent"] == nil)
        #expect(
            request["scope"]?.split(separator: " ").contains("chatgpt.tokens.use.direct") == true)
        #expect(request["ext_agent_host_id"] == fixture.authorizations[0]["ext_agent_host_id"])
        #expect(request["state"] != fixture.authorizations[0]["state"])
        #expect(request["nonce"] != fixture.authorizations[0]["nonce"])
        #expect(fixture.tokenRequests.allSatisfy { $0["client_id"] == "test-client" })
    }

    @Test(arguments: [false, true])
    func verifiedSignInSurvivesFailedCredentialWriteAndSavesWithoutRepeatingOAuth(
        _ identityOnly: Bool
    ) async throws {
        let fixture = try OAuthFixture(identityOnly: identityOnly)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        fixture.setSaveUnavailable(true)
        do {
            try await chatGPT.signIn()
            Issue.record("A failed credential write appeared successful")
        } catch let failure as ChatGPTFailure {
            #expect(failure.recovery == .save)
        }
        try await fixture.finishCallback()
        let retained = try #require(chatGPT.account)
        let grant = try #require(retained.session)
        #expect(retained.clientID == "test-client" && retained.subject == "test-subject")
        #expect(retained.email == "test@example.invalid")
        #expect(chatGPT.registrations.map(\.clientID) == ["test-client"])
        #expect(chatGPT.isSignedIn && chatGPT.canUsePlan == !identityOnly)
        #expect(grant.accessToken == (identityOnly ? nil : "test-access"))
        #expect(grant.refreshToken == (identityOnly ? nil : "test-refresh"))
        #expect(fixture.account == nil && fixture.registrations.isEmpty)
        #expect(fixture.authorizations.count == 1 && fixture.tokenRequests.count == 1)
        #expect(fixture.modelRequests == 0)

        fixture.setSaveUnavailable(false)
        try chatGPT.savePendingAccounts()
        let saved = try #require(fixture.account)
        #expect(saved.clientID == retained.clientID && saved.subject == retained.subject)
        #expect(saved.email == retained.email && saved.session?.idToken == grant.idToken)
        #expect(saved.session?.canUsePlan == !identityOnly)
        #expect(saved.session?.accessToken == grant.accessToken)
        #expect(saved.session?.refreshToken == grant.refreshToken)
        #expect(fixture.registrations.count == 1)
        #expect(fixture.authorizations.count == 1 && fixture.tokenRequests.count == 1)
        #expect(fixture.modelRequests == 0)
        #expect(chatGPT.isSignedIn && chatGPT.canUsePlan == !identityOnly)
    }

    @Test func emptyIssuedClientNeverCreatesAnUnboundRegistration() async throws {
        let fixture = try OAuthFixture()
        fixture.invalidate(.emptyClient)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        do {
            try await chatGPT.signIn()
            Issue.record("An empty issued client was accepted")
        } catch {}
        try await fixture.finishCallback()
        #expect(fixture.registrations.isEmpty && !chatGPT.isSignedIn)
        #expect(fixture.tokenRequests.isEmpty)
    }

    @Test func logoutAndReturningSignInKeepVerifiedClientAndHostWithoutIdentityHint() async throws {
        let fixture = try OAuthFixture()
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        #expect(try await chatGPT.signOut())
        #expect(!chatGPT.isSignedIn && fixture.account?.session == nil)
        #expect(
            fixture.account?.clientID == "test-client" && fixture.account?.subject == "test-subject"
        )
        let restored = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await restored.restore()
        try await restored.signIn()
        try await fixture.finishCallback()
        #expect(restored.isSignedIn && restored.canUsePlan)
        let request = fixture.authorizations[1]
        #expect(request["client_id"] == "test-client" && request["agent_name_hint"] == nil)
        #expect(request["id_token_hint"] == nil && request["prompt"] == nil)
        #expect(request["ext_agent_host_id"] == fixture.authorizations[0]["ext_agent_host_id"])
    }

    @Test(arguments: [OAuthFixture.InvalidIdentity.subject, .nonce, .callbackClient, .audience])
    private func invalidIdentityNeverOverwritesVerifiedRegistration(
        _ invalid: OAuthFixture.InvalidIdentity
    )
        async throws
    {
        let fixture = try OAuthFixture()
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        let originalToken = try #require(fixture.account?.session?.idToken)
        fixture.invalidate(invalid)
        do {
            try await chatGPT.signIn()
            Issue.record("Invalid OAuth identity replaced an existing account")
        } catch {}
        try await fixture.finishCallback()
        #expect(
            chatGPT.account?.subject == "test-subject" && chatGPT.account?.clientID == "test-client"
        )
        #expect(fixture.account?.session?.idToken == originalToken && chatGPT.canUsePlan)
        #expect(fixture.tokenRequests.count == (invalid == .callbackClient ? 1 : 2))
    }

    @Test(arguments: ["other-subject", "test-subject"])
    func anotherAccountKeepsDistinctRegistrationsAndSavedSelectionReusesItsClient(_ subject: String)
        async throws
    {
        let fixture = try OAuthFixture()
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        #expect(try await chatGPT.signOut())
        fixture.useIdentity(client: "another-client", subject: subject)
        try chatGPT.selectAccount(clientID: nil)
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        #expect(chatGPT.registrations.count == 2 && fixture.registrations.count == 2)
        #expect(
            chatGPT.account?.clientID == "another-client" && chatGPT.account?.subject == subject)
        #expect(fixture.authorizations[1]["client_id"] == "dynamic_agent_client")
        #expect(fixture.authorizations[1]["id_token_hint"] == nil)
        let previous = try #require(fixture.registrations.first { $0.clientID == "test-client" })
        #expect(previous.subject == "test-subject" && previous.session == nil)
        #expect(try await chatGPT.signOut())
        try chatGPT.selectAccount(clientID: "test-client")
        fixture.useIdentity(client: "test-client", subject: "test-subject")
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        #expect(
            chatGPT.account?.clientID == "test-client" && chatGPT.account?.subject == "test-subject"
        )
        #expect(fixture.authorizations[2]["client_id"] == "test-client")
        #expect(fixture.authorizations[2]["agent_name_hint"] == nil)
        #expect(fixture.registrations.count == 2)
        #expect(Set(fixture.authorizations.compactMap { $0["ext_agent_host_id"] }).count == 1)
    }

    @Test func anotherAccountSelectionWaitsForSignInAndSurvivesRestore() async throws {
        let fixture = try OAuthFixture()
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await chatGPT.restore()
        try await chatGPT.signIn()
        try await fixture.finishCallback()
        do {
            try chatGPT.selectAccount(clientID: nil)
            Issue.record("Signed-in account allowed another account to be selected")
        } catch {}
        #expect(chatGPT.account?.clientID == "test-client" && chatGPT.isSignedIn)
        #expect(try await chatGPT.signOut())
        let model = Model(chatGPT: chatGPT, defaults: fixture.defaults)
        try await loaded(model)
        model.selectAccount("")
        #expect(model.selectedAccountID.isEmpty && model.account.isEmpty)
        #expect(model.savedAccounts.count == 1 && fixture.registrations.count == 1)
        #expect(!model.working && fixture.authorizations.count == 1)
        #expect(fixture.account == nil)
        await model.shutdown()

        let restored = Model(
            chatGPT: ChatGPT(
                session: http, storage: fixture.storage, defaults: fixture.defaults,
                openAuthorization: fixture.open), defaults: fixture.defaults)
        try await loaded(restored)
        #expect(restored.selectedAccountID.isEmpty && restored.savedAccounts.count == 1)
        #expect(fixture.authorizations.count == 1)
        fixture.useIdentity(client: "another-client", subject: "another-subject")
        restored.authenticate()
        #expect(restored.working && restored.status == "Signing in…")
        restored.selectAccount("test-client")
        #expect(restored.selectedAccountID.isEmpty)
        try await loaded(restored)
        try await fixture.finishCallback()
        #expect(fixture.authorizations.count == 2)
        #expect(fixture.authorizations[1]["client_id"] == "dynamic_agent_client")
        #expect(fixture.authorizations[1]["id_token_hint"] == nil)
        #expect(restored.selectedAccountID == "another-client")
        #expect(restored.account == "test@example.invalid" && restored.savedAccounts.count == 2)
        #expect(fixture.registrations.first { $0.clientID == "test-client" }?.session == nil)
        await restored.shutdown()
    }

    @Test func unreadAccountBankCannotBeMutatedAndRetryPreservesEveryRegistration() async throws {
        let fixture = try OAuthFixture()
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let existing = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        try await existing.restore()
        try await existing.signIn()
        try await fixture.finishCallback()
        #expect(try await existing.signOut())
        fixture.useIdentity(client: "second-client", subject: "second-subject")
        try existing.selectAccount(clientID: nil)
        try await existing.signIn()
        try await fixture.finishCallback()
        #expect(try await existing.signOut())
        let saved = fixture.registrations
        let fresh = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        fixture.setLoadUnavailable(true)
        do {
            try await fresh.restore()
            Issue.record("Unavailable Keychain appeared restored")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .restore) }
        #expect(!fresh.accountsRestored)
        do {
            try await fresh.signIn()
            Issue.record("Unread account bank allowed sign-in")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .restore) }
        for client in ["test-client", nil] as [String?] {
            do {
                try fresh.selectAccount(clientID: client)
                Issue.record("Unread account bank allowed account selection")
            } catch let failure as ChatGPTFailure { #expect(failure.recovery == .restore) }
        }
        do {
            _ = try await fresh.signOut()
            Issue.record("Unread account bank allowed sign-out")
        } catch let failure as ChatGPTFailure { #expect(failure.recovery == .restore) }
        #expect(fixture.authorizations.count == 2)
        #expect(fixture.registrations.map(\.clientID) == saved.map(\.clientID))
        #expect(fixture.registrations.map(\.subject) == saved.map(\.subject))
        fixture.setLoadUnavailable(false)
        try await fresh.restore()
        #expect(fresh.accountsRestored && fresh.registrations.count == 2)
        fixture.useIdentity(client: "third-client", subject: "third-subject")
        try fresh.selectAccount(clientID: nil)
        try await fresh.signIn()
        try await fixture.finishCallback()
        #expect(
            Set(fixture.registrations.map(\.clientID)) == [
                "test-client", "second-client", "third-client",
            ])
    }

    @Test func failedPlanConsentKeepsWrongAccountFeedbackInsteadOfReloadingOldGrant() async throws {
        let fixture = try OAuthFixture(identityOnly: true)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        let model = Model(chatGPT: chatGPT, defaults: fixture.defaults)
        try await loaded(model)
        model.authenticate()
        #expect(model.working && model.status == "Signing in…")
        try await loaded(model)
        try await fixture.finishCallback()
        #expect(model.feedback?.recovery == .enablePlan && model.needsPlanPermission)
        #expect(fixture.modelRequests == 0)
        fixture.allowPlan()
        fixture.invalidate(.subject)
        model.enablePlanUsage()
        #expect(model.working && model.status == "Waiting for permission…")
        try await loaded(model)
        try await fixture.finishCallback()
        #expect(model.feedback?.message == ChatGPTFailure.wrongAccount.message)
        #expect(model.feedback?.recovery == ChatGPTFailure.Recovery.none)
        #expect(model.needsPlanPermission && model.models.isEmpty)
        #expect(fixture.account?.clientID == "test-client")
        #expect(fixture.account?.subject == "test-subject")
        #expect(fixture.registrations.count == 1 && fixture.modelRequests == 0)
        #expect(fixture.authorizations.last?["prompt"] == "consent")
        await model.shutdown()
    }

    @Test(arguments: [false, true], [false, true])
    func failedAuthorizationRestartsTheRequestedFlow(_ planConsent: Bool, _ expiredIdentity: Bool)
        async throws
    {
        let fixture = try OAuthFixture(identityOnly: planConsent)
        let http = session(fixture)
        defer {
            http.invalidateAndCancel()
            OAuthHTTP.route.use(nil)
            fixture.cleanUp()
        }
        let chatGPT = ChatGPT(
            session: http, storage: fixture.storage, defaults: fixture.defaults,
            openAuthorization: fixture.open)
        let model = Model(chatGPT: chatGPT, defaults: fixture.defaults)
        try await loaded(model)
        if planConsent {
            model.authenticate()
            try await loaded(model)
            try await fixture.finishCallback()
            #expect(model.needsPlanPermission)
        }
        let previousIdentity = fixture.account?.session?.idToken
        if expiredIdentity {
            fixture.invalidate(.expired)
        } else {
            fixture.rejectCodeExchange(true)
        }
        if planConsent { model.enablePlanUsage() } else { model.authenticate() }
        try await loaded(model)
        try await fixture.finishCallback()
        let failure = try #require(model.feedback)
        if expiredIdentity {
            #expect(failure.status == nil && failure.code == nil)
        } else {
            #expect(failure.status == 400 && failure.code == "invalid_grant")
            #expect(failure.requestID == "oauth-test-request")
            #expect(failure.responseBody == Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        #expect(!failure.isTerminalRefresh && !failure.message.contains("expired or was revoked"))
        #expect(model.recovery == (planConsent ? .enablePlan : .signIn) && model.canRecover)
        #expect(fixture.account?.session?.idToken == previousIdentity)
        #expect(fixture.registrations.count == (planConsent ? 1 : 0))
        let authorizations = fixture.authorizations.count
        let exchanges = fixture.tokenRequests.count
        let failedAuthorization = try #require(fixture.authorizations.last)
        let failedExchange = try #require(fixture.tokenRequests.last)
        await Task.yield()
        #expect(
            fixture.authorizations.count == authorizations
                && fixture.tokenRequests.count == exchanges)
        fixture.allowPlan()
        fixture.invalidate(nil)
        fixture.rejectCodeExchange(false)
        model.recover()
        try await loaded(model)
        try await fixture.finishCallback()
        let restarted = try #require(fixture.authorizations.last)
        #expect(fixture.authorizations.count == authorizations + 1)
        #expect(fixture.tokenRequests.count == exchanges + 1)
        #expect(restarted["prompt"] == (planConsent ? "consent" : nil))
        #expect(restarted["state"] != failedAuthorization["state"])
        #expect(restarted["nonce"] != failedAuthorization["nonce"])
        #expect(restarted["code_challenge"] != failedAuthorization["code_challenge"])
        #expect(fixture.tokenRequests.last?["code"] != failedExchange["code"])
        #expect(model.canStartSession && !model.needsPlanPermission && model.error.isEmpty)
        #expect(fixture.registrations.count == 1)
        if planConsent { #expect(restarted["client_id"] == "test-client") }
        await model.shutdown()
    }

    private func loaded(_ model: Model, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.working, ContinuousClock.now < deadline { await Task.yield() }
        try #require(!model.working, sourceLocation: sourceLocation)
    }

}
