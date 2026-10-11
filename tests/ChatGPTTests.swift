import Foundation
@preconcurrency import Network
import Testing

@testable import SkillIssue

@MainActor private final class CallbackPeerState {
    var connected = false
    var closed = false
}

private final class TestDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() {
        super.init(suiteName: "skill-issue-tests")!
    }
    override func string(forKey defaultName: String) -> String? {
        lock.withLock { values[defaultName] as? String }
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }
    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }
}

private final class StoredCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    private var log: [String] = []
    var rejectDeletion = false
    init(expired: Bool = false) {
        value = Credentials(
            clientID: "fake-client", subject: "fake-subject", email: "fake@example.invalid",
            idToken: "fake-id", accessToken: "old-access", refreshToken: "old-refresh",
            expires: expired ? .distantPast : Date().addingTimeInterval(3600))
    }
    var events: [String] { lock.withLock { log } }
    var current: Credentials? { lock.withLock { value } }
    var storage: CredentialStorage {
        CredentialStorage(
            load: { [self] in lock.withLock { value } },
            save: { [self] next in
                lock.withLock {
                    value = next
                    log.append("save:\(next.refreshToken)")
                }
            },
            delete: { [self] in
                try lock.withLock {
                    if rejectDeletion { throw AppFailure.failed }
                    value = nil
                    log.append("delete")
                }
            })
    }
}

private final class TestHTTP: @unchecked Sendable {
    enum Output: Sendable { case text, refusal, empty, whitespace }
    private let lock = NSLock()
    private var refresh: MockHTTPProtocol?
    private var modelRequests = 0
    private let output: Output
    init(output: Output = .empty) { self.output = output }
    var refreshPending: Bool { lock.withLock { refresh != nil } }
    var modelsRequested: Int { lock.withLock { modelRequests } }
    func finishRefresh() {
        let pending = lock.withLock {
            let pending = refresh
            refresh = nil
            return pending
        }
        pending?.respond([
            "access_token": "replacement-access", "refresh_token": "replacement-refresh",
            "expires_in": 3600, "scope": "chatgpt.tokens.use.direct", "token_type": "bearer",
        ])
    }
    func receive(_ request: MockHTTPProtocol) {
        switch request.request.url!.path {
        case "/v1/models":
            lock.withLock { modelRequests += 1 }
            request.respond(["models": [["slug": "gpt-6.1-sol", "visibility": "list"]]])
        case "/api/accounts/oauth/token": lock.withLock { refresh = request }
        case "/.well-known/openid-configuration":
            request.respond([
                "issuer": "https://auth.openai.com",
                "revocation_endpoint": "https://auth.openai.com/revoke",
            ])
        case "/revoke": request.respond([:])
        case "/v1/responses":
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
    static func session(server: TestHTTP) -> URLSession {
        lock.withLock { Self.server = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.server }?.receive(self) }
    override func stopLoading() {}
    func respond(_ value: [String: Any]) {
        // Fixture dictionaries contain only JSON-compatible values.
        // swiftlint:disable:next force_try
        respond(try! JSONSerialization.data(withJSONObject: value), contentType: "application/json")
    }
    func respond(_ data: Data, contentType: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) @MainActor
struct ChatGPTTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
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
        let stored = StoredCredentials(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let refresh = Task { try await chatGPT.prepareSession() }
        try await waitUntil { server.refreshPending }
        var entered = false
        let signOut = Task {
            entered = true
            try await chatGPT.signOut()
        }
        try await waitUntil { entered }
        #expect(stored.events.isEmpty)
        do {
            try await chatGPT.prepareSession()
            Issue.record("A new request was allowed during sign out")
        } catch {}
        server.finishRefresh()
        _ = try? await refresh.value
        try await signOut.value
        #expect(stored.events == ["save:replacement-refresh", "delete"])
        #expect(server.modelsRequested == 0)
        #expect(stored.current == nil)
        #expect(chatGPT.credentials == nil)
    }

    @Test func deletionFailureKeepsAccountConnected() async throws {
        let stored = StoredCredentials()
        stored.rejectDeletion = true
        let session = MockHTTPProtocol.session(server: TestHTTP())
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        try await chatGPT.restore()
        do {
            try await chatGPT.signOut()
            Issue.record("Failed deletion was accepted")
        } catch {}
        #expect(stored.current != nil)
        #expect(chatGPT.credentials != nil)
        try await chatGPT.prepareSession()
    }

    @Test func shutdownWaitsForRotatingRefreshToReachStorage() async throws {
        let stored = StoredCredentials(expired: true)
        let server = TestHTTP()
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = ChatGPT(session: session, storage: stored.storage, defaults: TestDefaults())
        let model = Model(chatGPT: chatGPT)
        try await waitUntil { !model.working }
        let refresh = Task { try await chatGPT.prepareSession() }
        try await waitUntil { server.refreshPending }
        var finished = false
        refresh.cancel()
        let shutdown = Task {
            await model.shutdown()
            finished = true
        }
        try await waitUntil { model.status == "Ready" && !model.working }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished)
        #expect(stored.events.isEmpty)
        server.finishRefresh()
        _ = try? await refresh.value
        await shutdown.value
        #expect(finished)
        #expect(stored.current?.refreshToken == "replacement-refresh")
        #expect(stored.events == ["save:replacement-refresh"])
        #expect(server.modelsRequested == 0)
    }

    @Test func refusalIsVisibleAndEmptyCompletionFails() async throws {
        for output in [TestHTTP.Output.text, .refusal, .empty, .whitespace] {
            let session = MockHTTPProtocol.session(server: TestHTTP(output: output))
            defer { session.invalidateAndCancel() }
            let chatGPT = ChatGPT(
                session: session, storage: StoredCredentials().storage, defaults: TestDefaults())
            try await chatGPT.restore()
            try await chatGPT.prepareSession()
            var text = ""
            var failed = false
            do { try await chatGPT.answer(input: [], language: "English") { text += $0 } } catch {
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
}
