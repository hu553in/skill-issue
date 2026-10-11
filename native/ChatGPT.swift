import AppKit
import CryptoKit
import JOSESwift
@preconcurrency import Network
import OpenAPIRuntime
import Security

// The SSE decoder takes byte chunks and has no line-size limit. Bound URLSession's
// input before it reaches the decoder, flushing on LF so tokens never wait for a full buffer.
private struct ResponseByteChunks: AsyncSequence, Sendable {
    let bytes: URLSession.AsyncBytes
    func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes.makeAsyncIterator()) }
    struct Iterator: AsyncIteratorProtocol {
        var bytes: URLSession.AsyncBytes.Iterator
        mutating func next() async throws -> ArraySlice<UInt8>? {
            var chunk: [UInt8] = []
            while let byte = try await bytes.next() {
                try Task.checkCancellation()
                if byte == 10 {
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

struct Credentials: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expires: Date
}

struct CredentialStorage: Sendable {
    var load: @Sendable () throws -> Credentials?
    var save: @Sendable (Credentials) throws -> Void
    var delete: @Sendable () throws -> Void

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.github.hu553in.skill-issue",
            kSecAttrAccount as String: "chatgpt",
        ]
    }
    static let keychain = Self(
        load: {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(
                query().merging([
                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                ]) { _, new in new } as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw AppFailure.failed
            }
            return try JSONDecoder().decode(Credentials.self, from: data)
        },
        save: { value in
            let attributes: [String: Any] = [
                kSecValueData as String: try JSONEncoder().encode(value)
            ]
            var status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(
                    query().merging(attributes) { _, new in new }.merging([
                        kSecAttrAccessible as String:
                            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    ]) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw AppFailure.failed }
        },
        delete: {
            let status = SecItemDelete(query() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppFailure.failed
            }
        })
}

@MainActor
final class ChatGPT {
    private(set) var credentials: Credentials?
    private let resource = "https://api.openai.com/v1"
    private let session: URLSession
    private let storage: CredentialStorage
    private let defaults: UserDefaults
    private var discovery: [String: Any]?
    private var refreshTask: Task<String, Error>?
    private var sessionConfiguration: (model: String, effort: String?)?
    private var signingOut = false

    init(
        session: URLSession = .shared, storage: CredentialStorage = .keychain,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.storage = storage
        self.defaults = defaults
    }

    func restore() async throws {
        let storage = storage
        credentials = try await Task.detached { try storage.load() }.value
    }

    private func save(_ value: Credentials) throws {
        try storage.save(value)
        credentials = value
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

    func signIn() async throws {
        guard !signingOut else { throw AppFailure.failed }
        let server = try CallbackServer()
        defer { server.stop() }
        let redirect = try await server.start()
        let state = Data.random().base64URLEncodedString()
        let nonce = Data.random().base64URLEncodedString()
        let verifier = Data.random().base64URLEncodedString()
        let host = defaults.string(forKey: "hostID") ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(host, forKey: "hostID")
        let existingClient = credentials?.clientID ?? defaults.string(forKey: "issuedClientID")
        var parameters = [
            "client_id": existingClient ?? "dynamic_agent_client", "ext_agent_host_id": host,
            "response_type": "code", "redirect_uri": redirect,
            "scope":
                "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": resource, "state": state, "nonce": nonce, "code_challenge_method": "S256",
            "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString(),
        ]
        if existingClient == nil { parameters["agent_name_hint"] = "Skill Issue" }
        if let credentials { parameters["id_token_hint"] = credentials.idToken }
        var authorize = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        authorize.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = authorize.url, NSWorkspace.shared.open(url) else { throw AppFailure.failed }
        let callback = try await server.callback()
        guard callback["state"] == state, callback["error"] == nil, let code = callback["code"]
        else { throw AppFailure.failed }
        let client = callback["client_id"] ?? existingClient
        guard let client, client != "dynamic_agent_client",
            existingClient == nil || existingClient == client
        else { throw AppFailure.failed }
        defaults.set(client, forKey: "issuedClientID")
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": client, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": resource,
        ])
        guard let idToken = tokens["id_token"] as? String else { throw AppFailure.failed }
        let claims = try await identity(idToken, client: client, nonce: nonce)
        guard let subject = claims["sub"] as? String, !subject.isEmpty,
            credentials == nil || credentials?.subject == subject
        else { throw AppFailure.failed }
        let next = try credential(
            tokens, client: client, subject: subject,
            email: claims["email"] as? String ?? "Connected", idToken: idToken)
        try save(next)
    }

    private func identity(_ token: String, client: String, nonce: String) async throws -> [String:
        Any]
    {
        let jws = try JWS(compactSerialization: token)
        let parts = token.split(separator: ".")
        guard parts.count == 3, let headerData = Data(base64URLEncoded: String(parts[0])),
            let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            header["alg"] as? String == "RS256", let kid = header["kid"] as? String
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
            claims["nonce"] as? String == nonce, let exp = claims["exp"] as? Double,
            let iat = claims["iat"] as? Double, exp > Date().timeIntervalSince1970 - 5,
            iat <= Date().timeIntervalSince1970 + 5
        else { throw AppFailure.failed }
        let audiences = (claims["aud"] as? [String]) ?? [claims["aud"] as? String ?? ""]
        guard audiences.contains(client), audiences.count == 1 || claims["azp"] as? String == client
        else { throw AppFailure.failed }
        return claims
    }

    private func credential(
        _ tokens: [String: Any], client: String, subject: String, email: String, idToken: String
    ) throws -> Credentials {
        guard let access = tokens["access_token"] as? String,
            let refresh = tokens["refresh_token"] as? String,
            let expiry = tokens["expires_in"] as? Double, let scope = tokens["scope"] as? String,
            scope.split(separator: " ").contains("chatgpt.tokens.use.direct"),
            (tokens["token_type"] as? String)?.lowercased() == "bearer"
        else { throw AppFailure.failed }
        return Credentials(
            clientID: client, subject: subject, email: email, idToken: idToken, accessToken: access,
            refreshToken: refresh, expires: Date().addingTimeInterval(expiry))
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
        guard !signingOut else { throw AppFailure.failed }
        if let refreshTask {
            let token = try await refreshTask.value
            guard !signingOut, credentials?.accessToken == token else { throw AppFailure.failed }
            return token
        }
        guard let current = credentials else { throw AppFailure.failed }
        if current.expires >= Date().addingTimeInterval(60) { return current.accessToken }
        // Refresh tokens rotate. Cancellation of an answer must not start two
        // refreshes or discard the replacement token before it reaches Keychain.
        let task = Task { [self] in
            let result = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": current.clientID,
                "refresh_token": current.refreshToken, "resource": resource,
            ])
            let next = try credential(
                result, client: current.clientID, subject: current.subject, email: current.email,
                idToken: result["id_token"] as? String ?? current.idToken)
            try save(next)
            return next.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        guard !signingOut, credentials?.accessToken == token else { throw AppFailure.failed }
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
        sessionConfiguration = nil
        guard model.efforts.isEmpty ? effort.isEmpty : model.efforts.contains(effort) else {
            throw AppFailure.failed
        }
        _ = try await accessToken()
        try Task.checkCancellation()
        sessionConfiguration = (model.slug, effort.isEmpty ? nil : effort)
    }

    func finishPendingRefresh() async {
        _ = try? await refreshTask?.value
    }

    func signOut() async throws {
        guard !signingOut else { throw AppFailure.failed }
        signingOut = true
        defer { signingOut = false }
        // A rotating refresh must finish before deleting its replacement grant.
        await finishPendingRefresh()
        let old = credentials
        try storage.delete()
        credentials = nil
        sessionConfiguration = nil
        defaults.removeObject(forKey: "issuedClientID")
        if let old {
            let config = try await configuration()
            guard let endpoint = config["revocation_endpoint"] as? String,
                let url = URL(string: endpoint), url.scheme == "https",
                url.host == "auth.openai.com"
            else { throw AppFailure.failed }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form([
                "token": old.refreshToken, "token_type_hint": "refresh_token",
                "client_id": old.clientID,
            ])
            let (_, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.failed }
        }
    }

    func answer(input: [[String: Any]], language: String, delta: (String) -> Void) async throws {
        guard let configuration = sessionConfiguration else { throw AppFailure.failed }
        let access = try await accessToken()
        try Task.checkCancellation()
        let prompt = try String(
            contentsOf: Bundle.module.url(
                forResource: "prompt", withExtension: "md", subdirectory: "Resources")!,
            encoding: .utf8)
        var request = URLRequest(url: URL(string: "\(resource)/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": configuration.model, "store": false, "stream": true,
            "instructions": prompt + "\nTrusted session setting: output language is \(language).",
            "input": input,
        ]
        if let effort = configuration.effort { body["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        #if DEBUG
            FileHandle.standardError.write(
                Data(
                    "[chatgpt] Responses HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)\n"
                        .utf8))
        #endif
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.failed }
        var completed = false
        var hasText = false
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
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                delta(text)
            }
            if type == "response.completed" {
                completed = true
                break
            }
            if ["response.failed", "response.incomplete", "error"].contains(type) {
                throw AppFailure.failed
            }
        }
        guard completed && hasText else { throw AppFailure.failed }
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        #if DEBUG
            FileHandle.standardError.write(
                Data(
                    "[chatgpt] \(request.url?.path ?? "") HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)\n"
                        .utf8))
        #endif
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
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
                    completion: .contentProcessed { _ in connection.cancel() })
                self.continuation.yield(values)
                self.continuation.finish()
            }
        }
    }
}
