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
    override func integer(forKey defaultName: String) -> Int {
        lock.withLock { values[defaultName] as? Int ?? 0 }
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
    private var responseBodies: [[String: Any]] = []
    private var responseRequests: [URLRequest] = []
    private var responseCancellations = 0
    private let output: Output
    private let stream: [Data]?
    private let finishStream: Bool
    private let responseStatus: Int
    init(
        output: Output = .empty, models: [[String: Any]] = [catalogModel("gpt-6-luna")],
        stream: [Data]? = nil, finishStream: Bool = true, responseStatus: Int = 200
    ) {
        self.output = output
        catalog = models
        self.stream = stream
        self.finishStream = finishStream
        self.responseStatus = responseStatus
    }
    var refreshPending: Bool { lock.withLock { refresh != nil } }
    var modelsRequested: Int { lock.withLock { modelRequests } }
    var requests: [[String: Any]] { lock.withLock { responseBodies } }
    var wireRequests: [URLRequest] { lock.withLock { responseRequests } }
    var cancelledResponses: Int { lock.withLock { responseCancellations } }
    func cancelled(_ request: URLRequest) {
        if request.url?.path == "/v1/responses" {
            lock.withLock { responseCancellations += 1 }
        }
    }
    func setCatalog(_ models: [[String: Any]], status: Int = 200) {
        lock.withLock {
            catalog = models
            catalogStatus = status
        }
    }
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
            let (models, status) = lock.withLock {
                modelRequests += 1
                return (catalog, catalogStatus)
            }
            request.respond(["models": models], status: status)
        case "/api/accounts/oauth/token": lock.withLock { refresh = request }
        case "/.well-known/openid-configuration":
            request.respond([
                "issuer": "https://auth.openai.com",
                "revocation_endpoint": "https://auth.openai.com/revoke",
            ])
        case "/revoke": request.respond([:])
        case "/v1/responses":
            lock.withLock { responseRequests.append(request.request) }
            var body = request.request.httpBody ?? Data()
            if let stream = request.request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            if let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                lock.withLock { responseBodies.append(payload) }
            }
            if let stream {
                request.respond(
                    stream, contentType: "text/event-stream", status: responseStatus,
                    finished: finishStream)
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
        server?.receive(self)
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
    func respond(_ chunks: [Data], contentType: String, status: Int = 200, finished: Bool = true) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finished { client?.urlProtocolDidFinishLoading(self) }
    }
}

@Suite(.serialized) @MainActor
struct ChatGPTTests {
    private func configuredChatGPT(session: URLSession) async throws -> ChatGPT {
        let chatGPT = ChatGPT(
            session: session, storage: StoredCredentials().storage, defaults: TestDefaults())
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
                    session: session, storage: StoredCredentials().storage,
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
        let stored = StoredCredentials()
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
        model.working = true
        model.selectModel("gpt-6-luna")
        model.selectEffort("low")
        #expect(!model.canSelectModel && !model.canSelectEffort)
        #expect(model.modelSlug == "other" && model.reasoningEffort == "high")
        model.working = false
        model.state.live = true
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

    @Test func catalogFailureKeepsControlsDisabledAndRetryRecovers() async throws {
        let server = TestHTTP()
        server.setCatalog([], status: 503)
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let defaults = TestDefaults()
        let model = Model(
            chatGPT: ChatGPT(
                session: session, storage: StoredCredentials().storage,
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
        model.retryModels()
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
            session: session, storage: StoredCredentials().storage, defaults: TestDefaults())
        try await chatGPT.restore()
        let models = try await chatGPT.listModels()
        for (index, effort) in ["high", "", "", "none"].enumerated() {
            try await chatGPT.prepareSession(model: models[index], effort: effort)
            try await chatGPT.answer(input: [], language: "English") { _ in }
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
            try await chatGPT.answer(input: [], language: "English") { _ in }
            Issue.record("An old session selection remained usable after failed preparation")
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
        let stored = StoredCredentials(expired: true)
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
            try await chatGPT.signOut()
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
        _ = try await chatGPT.listModels()
    }

    @Test func shutdownWaitsForRotatingRefreshToReachStorage() async throws {
        let stored = StoredCredentials(expired: true)
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
        #expect(stored.current?.refreshToken == "replacement-refresh")
        #expect(stored.events == ["save:replacement-refresh"])
        #expect(server.modelsRequested == 0)
        #expect(model.models.isEmpty && !model.canStartSession)
    }

    @Test func refusalIsVisibleAndEmptyCompletionFails() async throws {
        for output in [TestHTTP.Output.text, .refusal, .empty, .whitespace] {
            let session = MockHTTPProtocol.session(server: TestHTTP(output: output))
            defer { session.invalidateAndCancel() }
            let chatGPT = ChatGPT(
                session: session, storage: StoredCredentials().storage, defaults: TestDefaults())
            try await chatGPT.restore()
            let models = try await chatGPT.listModels()
            try await chatGPT.prepareSession(model: models[0], effort: "low")
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

    @Test func eventStreamFramingPreservesUnicodeAndMultilineData() async throws {
        for delimiter in ["\n", "\r\n"] {
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
            try await chatGPT.answer(input: [], language: "Russian") { text += $0 }
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
            do { try await chatGPT.answer(input: [], language: "English") { text += $0 } } catch {
                failed = true
            }
            #expect(failed && text == "Partial")
            #expect(server.wireRequests.count == 1)
        }
    }

    @Test func eventStreamLineLimitIsEnforcedBeforeDispatch() async throws {
        for delimiter in ["\n", "\r\n"] {
            for size in [256_000, 256_001] {
                let prefix = "data: {\"type\":\"response.output_text.delta\",\"delta\":\""
                let suffix = "\"}"
                // The bound counts CR before LF, matching the existing network contract.
                let text = String(
                    repeating: "x",
                    count: size - prefix.utf8.count - suffix.utf8.count
                        - (delimiter == "\r\n" ? 1 : 0))
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
                    try await chatGPT.answer(input: [], language: "English") { received += $0 }
                } catch {
                    failed = true
                }
                #expect(failed == (size > 256_000))
                #expect(received == (size > 256_000 ? "" : text))
                #expect(server.wireRequests.count == 1)
            }
        }
    }

    @Test func cancelledEventStreamStopsRequestWithoutReplay() async throws {
        let server = TestHTTP(
            stream: [
                Data(
                    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8
                )
            ],
            finishStream: false)
        let session = MockHTTPProtocol.session(server: server)
        defer { session.invalidateAndCancel() }
        let chatGPT = try await configuredChatGPT(session: session)
        var text = ""
        var finished = false
        var failed = false
        let answer = Task {
            defer { finished = true }
            do { try await chatGPT.answer(input: [], language: "English") { text += $0 } } catch {
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
        do { try await chatGPT.answer(input: [], language: "English") { text += $0 } } catch {
            failed = true
        }
        #expect(failed && text.isEmpty)
        #expect(server.wireRequests.count == 1)
    }
}
