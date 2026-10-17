import AppKit
import CryptoKit
import JOSESwift
@preconcurrency import Network
import OpenAPIRuntime
import Security

// The SSE decoder takes byte chunks and has no line-size limit. Bound URLSession's
// input before it reaches the decoder, flushing on CR or LF so tokens never wait for a full buffer.
private struct ResponseByteChunks: AsyncSequence, Sendable {
    let bytes: URLSession.AsyncBytes
    func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes.makeAsyncIterator()) }
    struct Iterator: AsyncIteratorProtocol {
        var bytes: URLSession.AsyncBytes.Iterator
        mutating func next() async throws -> ArraySlice<UInt8>? {
            var chunk: [UInt8] = []
            while let byte = try await bytes.next() {
                try Task.checkCancellation()
                if byte == 10 || byte == 13 {
                    chunk.append(byte)
                    return chunk[...]
                }
                chunk.append(byte)
                guard chunk.count <= 256_000 else { throw AppFailure.failed }
            }
            return chunk.isEmpty ? nil : chunk[...]
        }
    }
}

@MainActor
final class ChatGPT {
    private var accounts = ChatGPTAccounts()
    private var accountsNeedSaving = false
    private(set) var accountsRestored = false
    private(set) var requiresSignIn = false
    var accountStateChanged: ((ChatGPTFailure?) -> Void)?
    var account: ChatGPTAccount? { accounts.selected }
    var registrations: [ChatGPTAccount] { accounts.accounts }
    var isSignedIn: Bool { accountsRestored && account?.session != nil }
    var canUsePlan: Bool { accountsRestored && account?.session?.canUsePlan == true }
    private let resource = "https://api.openai.com/v1"
    private let session: URLSession
    private let storage: AccountStorage
    private let defaults: UserDefaults
    private let openAuthorization: (URL) -> Bool
    private var discovery: [String: Any]?
    private var refreshTask: Task<String, Error>?
    private var signingOut = false

    init(
        session: URLSession = .shared, storage: AccountStorage = .keychain,
        defaults: UserDefaults = .standard,
        openAuthorization: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.session = session
        self.storage = storage
        self.defaults = defaults
        self.openAuthorization = openAuthorization
    }

    func restore() async throws {
        let storage = storage
        accountsRestored = false
        requiresSignIn = false
        do {
            accounts = try await Task.detached { try storage.load() }.value ?? ChatGPTAccounts()
        } catch {
            throw ChatGPTFailure.accountStorageUnavailable
        }
        accountsRestored = true
        accountsNeedSaving = false
        accountStateChanged?(nil)
        // A bare issued ID from older versions was not bound to a verified identity.
        defaults.removeObject(forKey: "issuedClientID")
    }

    private func requireRestoredAccounts() throws {
        guard accountsRestored else { throw ChatGPTFailure.accountStorageUnavailable }
    }

    private func save(_ value: ChatGPTAccount) throws {
        try requireRestoredAccounts()
        var next = accounts
        if let index = next.accounts.firstIndex(where: { $0.clientID == value.clientID }) {
            next.accounts[index] = value
        } else {
            next.accounts.append(value)
        }
        next.selectedClientID = value.clientID
        accounts = next
        accountsNeedSaving = true
        try savePendingAccounts()
        accountStateChanged?(nil)
    }

    func savePendingAccounts() throws {
        try requireRestoredAccounts()
        guard accountsNeedSaving else { return }
        do {
            try storage.save(accounts)
            accountsNeedSaving = false
        } catch {
            accountStateChanged?(.credentialsNotSaved)
            throw ChatGPTFailure.credentialsNotSaved
        }
    }

    func selectAccount(clientID: String?) throws {
        try requireRestoredAccounts()
        guard !signingOut, !isSignedIn,
            clientID == nil || accounts.accounts.contains(where: { $0.clientID == clientID })
        else { throw AppFailure.failed }
        var next = accounts
        next.selectedClientID = clientID
        try storage.save(next)
        accounts = next
        accountsNeedSaving = false
        requiresSignIn = false
        accountStateChanged?(nil)
    }

    private func clearSession(failure: ChatGPTFailure? = nil) throws {
        try requireRestoredAccounts()
        guard let index = accounts.accounts.firstIndex(where: { $0.clientID == account?.clientID })
        else { return }
        // Known unusable tokens must stop being used even if Keychain refuses the write.
        accounts.accounts[index].session = nil
        accounts.accounts[index].pendingSession = nil
        requiresSignIn = false
        accountsNeedSaving = true
        do { try storage.save(accounts) } catch {
            accountStateChanged?(.tokenRemovalFailed)
            throw ChatGPTFailure.tokenRemovalFailed
        }
        accountsNeedSaving = false
        accountStateChanged?(failure)
    }

    private func configuration() async throws -> [String: Any] {
        if let discovery { return discovery }
        let value = try await json(
            URLRequest(
                url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
        guard value["issuer"] as? String == "https://auth.openai.com" else {
            throw AppFailure.failed
        }
        discovery = value
        return value
    }

    func signIn(requestPlanConsent: Bool = false) async throws {
        try Task.checkCancellation()
        try requireRestoredAccounts()
        guard !signingOut else { throw AppFailure.failed }
        let expectedAccount = account
        let server = try CallbackServer()
        defer { server.stop() }
        let redirect = try await server.start()
        try Task.checkCancellation()
        let state = Data.random().base64URLEncodedString()
        let nonce = Data.random().base64URLEncodedString()
        let verifier = Data.random().base64URLEncodedString()
        let host = defaults.string(forKey: "hostID") ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(host, forKey: "hostID")
        let existingClient = expectedAccount?.clientID
        var parameters = [
            "client_id": existingClient ?? "dynamic_agent_client", "ext_agent_host_id": host,
            "response_type": "code", "redirect_uri": redirect,
            "scope":
                "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": resource, "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString(),
        ]
        if existingClient == nil { parameters["agent_name_hint"] = "Skill Issue" }
        if let identity = expectedAccount?.session?.idToken {
            parameters["id_token_hint"] = identity
        }
        if requestPlanConsent { parameters["prompt"] = "consent" }
        var authorize = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        authorize.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = authorize.url, openAuthorization(url) else { throw AppFailure.failed }
        let callback = try await server.callback()
        guard callback["state"] == state, callback["error"] == nil, let code = callback["code"]
        else { throw AppFailure.failed }
        let client = callback["client_id"] ?? existingClient
        guard let client, !client.isEmpty, client != "dynamic_agent_client",
            existingClient == nil || existingClient == client
        else { throw AppFailure.failed }
        let tokens: [String: Any]
        do {
            tokens = try await tokenRequest([
                "grant_type": "authorization_code", "client_id": client, "code": code,
                "code_verifier": verifier, "redirect_uri": redirect, "resource": resource,
            ])
        } catch let failure as ChatGPTFailure where failure.isTerminalRefresh {
            // A rejected authorization code does not invalidate the saved session.
            throw failure.authorizationCodeFailure(requestPlanConsent: requestPlanConsent)
        }
        guard let idToken = tokens["id_token"] as? String else { throw AppFailure.failed }
        let claims: [String: Any]
        do {
            claims = try await identity(idToken, client: client, nonce: nonce)
        } catch let failure as ChatGPTFailure where failure.recovery == .signIn {
            throw failure.authorizationCodeFailure(requestPlanConsent: requestPlanConsent)
        }
        guard let subject = claims["sub"] as? String, !subject.isEmpty,
            expectedAccount == nil || expectedAccount?.subject == subject,
            !accounts.accounts.contains(where: { $0.clientID == client && $0.subject != subject })
        else { throw ChatGPTFailure.wrongAccount }
        let next = try grant(tokens, idToken: idToken)
        requiresSignIn = false
        try save(
            ChatGPTAccount(
                clientID: client, subject: subject,
                email: claims["email"] as? String ?? "Connected", session: next))
    }

    private func identity(_ token: String, client: String, nonce: String?) async throws -> [String:
        Any]
    {
        let jws = try JWS(compactSerialization: token)
        guard jws.header.algorithm == .RS256, let kid = jws.header.kid
        else { throw AppFailure.failed }
        let config = try await configuration()
        guard let uri = config["jwks_uri"] as? String, let url = URL(string: uri),
            url.scheme == "https", url.host == "auth.openai.com"
        else { throw AppFailure.failed }
        let set = try await json(URLRequest(url: url))
        guard let keys = set["keys"] as? [[String: Any]],
            let key = keys.first(where: {
                $0["kid"] as? String == kid && $0["kty"] as? String == "RSA"
            })
        else { throw AppFailure.failed }
        let publicKey: SecKey = try RSAPublicKey(data: JSONSerialization.data(withJSONObject: key))
            .converted(to: SecKey.self)
        guard let verifier = Verifier(signatureAlgorithm: .RS256, key: publicKey) else {
            throw AppFailure.failed
        }
        let payload = try jws.validate(using: verifier).payload.data()
        guard let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            claims["iss"] as? String == "https://auth.openai.com",
            nonce == nil || claims["nonce"] as? String == nonce, let exp = claims["exp"] as? Double,
            let iat = claims["iat"] as? Double,
            iat <= Date().timeIntervalSince1970 + 5
        else { throw AppFailure.failed }
        let audiences = (claims["aud"] as? [String]) ?? [claims["aud"] as? String ?? ""]
        guard audiences.contains(client), audiences.count == 1 || claims["azp"] as? String == client
        else { throw AppFailure.failed }
        guard exp > Date().timeIntervalSince1970 - 5 else { throw ChatGPTFailure.signInRequired }
        return claims
    }

    private func grant(
        _ tokens: [String: Any], idToken: String, previousScopes: [String]? = nil
    ) throws -> ChatGPTSession {
        let scopes: [String]
        if let value = tokens["scope"] {
            guard let scope = value as? String else { throw AppFailure.failed }
            scopes = scope.split(separator: " ").map(String.init)
        } else {
            guard let previousScopes else { throw AppFailure.failed }
            scopes = previousScopes
        }
        let access = tokens["access_token"] as? String
        let refresh = tokens["refresh_token"] as? String
        let expiry = tokens["expires_in"] as? Double
        if scopes.contains("chatgpt.tokens.use.direct") {
            guard let access, !access.isEmpty, let refresh, !refresh.isEmpty,
                let expiry, expiry.isFinite, expiry > 0,
                (tokens["token_type"] as? String)?.lowercased() == "bearer"
            else { throw AppFailure.failed }
        }
        return ChatGPTSession(
            idToken: idToken, accessToken: access, refreshToken: refresh,
            expires: expiry.map { Date().addingTimeInterval($0) }, scopes: scopes)
    }

    private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(
            url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        return try await json(request)
    }

    private func accessToken() async throws -> String {
        try requireRestoredAccounts()
        guard !signingOut else { throw AppFailure.failed }
        guard !requiresSignIn else { throw ChatGPTFailure.signInRequired }
        if let refreshTask {
            let token = try await refreshTask.value
            guard !signingOut, account?.session?.accessToken == token else {
                throw AppFailure.failed
            }
            return token
        }
        try savePendingAccounts()
        guard let current = account, let grant = current.session else {
            throw ChatGPTFailure.signInRequired
        }
        guard grant.canUsePlan else { throw ChatGPTFailure.planDisabled }
        guard let access = grant.accessToken, grant.refreshToken != nil,
            let expires = grant.expires
        else { throw AppFailure.failed }
        if current.pendingSession == nil, expires >= Date().addingTimeInterval(60) { return access }
        let renewable = current.pendingSession ?? grant
        let needsRefresh =
            current.pendingSession == nil
            || renewable.expires.map { $0 < Date().addingTimeInterval(60) } == true
        // Refresh tokens rotate. Cancellation of an answer must not start two
        // refreshes or discard the replacement token before it reaches Keychain.
        let task = Task { [self] in
            var refreshed = current
            if needsRefresh {
                guard let refresh = renewable.refreshToken else { throw AppFailure.failed }
                let result: [String: Any]
                do {
                    result = try await tokenRequest([
                        "grant_type": "refresh_token", "client_id": current.clientID,
                        "refresh_token": refresh, "resource": resource,
                    ])
                } catch let failure as ChatGPTFailure {
                    if failure.isTerminalRefresh {
                        try clearSession(failure: failure)
                    } else if failure.stopsSession {
                        accountStateChanged?(failure)
                    }
                    throw failure
                }
                refreshed.pendingSession = try self.grant(
                    result, idToken: result["id_token"] as? String ?? renewable.idToken,
                    previousScopes: renewable.scopes)
            }
            guard let next = refreshed.pendingSession else { throw AppFailure.failed }
            if next.idToken != grant.idToken {
                if needsRefresh {
                    // Persist rotation separately from the verified session. A key-fetch
                    // outage or app restart must not reuse the consumed refresh token.
                    try save(refreshed)
                }
                let claims: [String: Any]
                do {
                    claims = try await identity(next.idToken, client: current.clientID, nonce: nil)
                } catch let failure as ChatGPTFailure {
                    if failure.recovery == .signIn { requiresSignIn = true }
                    if failure.stopsSession { accountStateChanged?(failure) }
                    throw failure
                }
                guard claims["sub"] as? String == current.subject else {
                    try clearSession(failure: .signInRequired)
                    throw ChatGPTFailure.signInRequired
                }
            }
            refreshed.session = next
            refreshed.pendingSession = nil
            try save(refreshed)
            guard next.canUsePlan, let token = next.accessToken else {
                accountStateChanged?(.planDisabled)
                throw ChatGPTFailure.planDisabled
            }
            guard next.expires.map({ $0 > Date() }) == true else { throw ChatGPTFailure.generic }
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        guard !signingOut, account?.session?.accessToken == token else { throw AppFailure.failed }
        return token
    }

    func listModels() async throws -> [ChatGPTModel] {
        let access = try await accessToken()
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "\(resource)/models")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let list = try await json(request)
        guard let models = list["models"] as? [[String: Any]] else { throw AppFailure.failed }
        let available = try models.filter { $0["visibility"] as? String == "list" }
            .map { try ChatGPTModel(fields: $0) }
        guard !available.isEmpty, Set(available.map(\.slug)).count == available.count else {
            throw AppFailure.failed
        }
        return available
    }

    func prepareSession(model: ChatGPTModel, effort: String) async throws {
        guard model.supportsEffort(effort) else {
            throw AppFailure.failed
        }
        _ = try await accessToken()
        try Task.checkCancellation()
    }

    func finishPendingRefresh() async {
        _ = try? await refreshTask?.value
    }

    func signOut() async throws -> Bool {
        try requireRestoredAccounts()
        guard !signingOut else { throw AppFailure.failed }
        signingOut = true
        defer { signingOut = false }
        // Wait for rotation and revoke while the latest grant is still available.
        await finishPendingRefresh()
        guard let old = account, let grant = old.pendingSession ?? old.session else { return true }
        let confirmed = await revoke(grant, client: old.clientID)
        try clearSession()
        return confirmed
    }

    private func revoke(_ grant: ChatGPTSession, client: String) async -> Bool {
        guard let token = grant.refreshToken ?? grant.accessToken else { return false }
        for attempt in 0..<3 {
            if Task.isCancelled { return false }
            do {
                let config = try await configuration()
                guard let endpoint = config["revocation_endpoint"] as? String,
                    let url = URL(string: endpoint), url.scheme == "https",
                    url.host == "auth.openai.com"
                else { return false }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 10
                request.setValue(
                    "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = form([
                    "token": token,
                    "token_type_hint": grant.refreshToken == nil ? "access_token" : "refresh_token",
                    "client_id": client,
                ])
                let (_, response) = try await session.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
                if status == 200 { return true }
                if status < 500 { return false }
            } catch let failure as ChatGPTFailure {
                if let status = failure.status, status < 500 { return false }
            } catch {
                if !(error is URLError) { return false }
            }
            if attempt < 2 {
                do { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) } catch {
                    return false
                }
            }
        }
        return false
    }

    @discardableResult
    func answer(
        input: [[String: Any]], language: String, model: ChatGPTModel, effort: String,
        settings: AnswerSettings = AnswerSettings(),
        prompt: String? = nil,
        delta: (String) -> Void
    ) async throws -> [String: Int]? {
        do {
            guard model.supportsEffort(effort) else {
                throw AppFailure.failed
            }
            let access = try await accessToken()
            try Task.checkCancellation()
            let prompt = try prompt ?? SystemPrompt.load()
            var request = URLRequest(url: URL(string: "\(resource)/responses")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "model": model.slug, "store": false, "stream": true,
                "instructions": prompt
                    + "\nTrusted session setting: output language is \(language). "
                    + "Use this language for all your prose, including headings, even when candidate settings "
                    + "or observations request another prose language. Preserve code identifiers and explicitly "
                    + "requested foreign-language text.",
                "input": try settings.input(with: input),
            ]
            if !effort.isEmpty { body["reasoning"] = ["effort": effort] }
            if model.supportsVerbosity { body["text"] = ["verbosity": settings.verbosity.rawValue] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await session.bytes(for: request)
            #if DEBUG
                FileHandle.standardError.write(
                    Data(
                        "[chatgpt] Responses HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)\n"
                            .utf8))
            #endif
            guard let http = response as? HTTPURLResponse else { throw AppFailure.failed }
            guard http.statusCode == 200 else {
                throw try await ChatGPTFailure(bytes: bytes, response: http)
            }

            var completed = false
            var hasText = false
            var usage: [String: Int]?
            for try await event in ResponseByteChunks(bytes: bytes).asDecodedServerSentEvents() {
                try Task.checkCancellation()
                guard let data = event.data,
                    let body = try JSONSerialization.jsonObject(with: Data(data.utf8))
                        as? [String: Any],
                    let type = body["type"] as? String
                else { continue }
                if ["response.output_text.delta", "response.refusal.delta"].contains(type),
                    let text = body["delta"] as? String
                {
                    hasText =
                        hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    delta(text)
                }
                if type == "response.completed" {
                    if let response = body["response"] as? [String: Any],
                        let counts = response["usage"] as? [String: Any]
                    {
                        usage = [
                            "inputTokens": counts["input_tokens"] as? Int,
                            "outputTokens": counts["output_tokens"] as? Int,
                            "reasoningTokens": (counts["output_tokens_details"] as? [String: Any])?[
                                "reasoning_tokens"] as? Int,
                            "cachedInputTokens":
                                (counts["input_tokens_details"] as? [String: Any])?[
                                    "cached_tokens"] as? Int,
                        ].compactMapValues { $0 }
                    }
                    completed = true
                    break
                }
                if ["response.failed", "response.incomplete", "error"].contains(type) {
                    throw ChatGPTFailure(
                        status: http.statusCode, body: Data(data.utf8),
                        requestID: http.value(forHTTPHeaderField: "x-request-id"))
                }
            }
            guard completed && hasText else { throw AppFailure.failed }
            return usage
        } catch let error as URLError {
            #if DEBUG
                FileHandle.standardError.write(
                    Data("[chatgpt] Responses network error \(error.code.rawValue)\n".utf8))
            #endif
            try Task.checkCancellation()
            throw ChatGPTFailure.generic
        }
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch is URLError {
            try Task.checkCancellation()
            throw ChatGPTFailure.generic
        }
        #if DEBUG
            FileHandle.standardError.write(
                Data(
                    "[chatgpt] \(request.url?.path ?? "") HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)\n"
                        .utf8))
        #endif
        guard let http = response as? HTTPURLResponse else { throw AppFailure.failed }
        guard (200..<300).contains(http.statusCode) else {
            throw try await ChatGPTFailure(bytes: bytes, response: http)
        }
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
            }
        } catch is URLError {
            try Task.checkCancellation()
            throw ChatGPTFailure.generic
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AppFailure.failed }
        return result
    }
    private func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data(
            (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

@MainActor
final class CallbackServer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var stopped = false
    private let stream: AsyncThrowingStream<[String: String], Error>
    private let continuation: AsyncThrowingStream<[String: String], Error>.Continuation
    private var ready: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
        return try await withCheckedThrowingContinuation { ready in
            self.ready = ready
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = self.listener.port {
                        self.ready?.resume(
                            returning: "http://127.0.0.1:\(port.rawValue)/auth/callback")
                        self.ready = nil
                    } else if case .failed = state {
                        self.ready?.resume(throwing: AppFailure.failed)
                        self.ready = nil
                        self.continuation.finish(throwing: AppFailure.failed)
                    }
                }
            }
            listener.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled else { return }
                self?.ready?.resume(throwing: AppFailure.failed)
                self?.ready = nil
                self?.continuation.finish(throwing: AppFailure.failed)
            }
        }
    }
    func callback() async throws -> [String: String] {
        for try await result in stream { return result }
        throw AppFailure.failed
    }
    func stop() {
        stopped = true
        timeout?.cancel()
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
        continuation.finish()
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.stopped else {
                    connection.cancel()
                    return
                }
                let collected = buffer + (data ?? Data())
                guard error == nil, collected.count <= 16384 else {
                    connection.cancel()
                    return
                }
                let text = String(decoding: collected, as: UTF8.self)
                guard text.contains("\r\n\r\n") else {
                    if complete {
                        connection.cancel()
                    } else {
                        self.read(connection, buffer: collected)
                    }
                    return
                }
                let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET",
                    let url = URLComponents(string: "http://127.0.0.1\(parts[1])"),
                    url.path == "/auth/callback"
                else {
                    connection.cancel()
                    return
                }
                var values: [String: String] = [:]
                for item in url.queryItems ?? [] {
                    guard values[item.name] == nil else {
                        connection.cancel()
                        return
                    }
                    values[item.name] = item.value ?? ""
                }
                let body = "You can return to Skill Issue."
                let response =
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { [weak self, values] error in
                        connection.cancel()
                        Task { @MainActor in
                            guard let self, !self.stopped else { return }
                            if let error {
                                self.continuation.finish(throwing: error)
                            } else {
                                // The caller may stop the server as soon as it receives the callback.
                                self.continuation.yield(values)
                                self.continuation.finish()
                            }
                        }
                    })
            }
        }
    }
}
