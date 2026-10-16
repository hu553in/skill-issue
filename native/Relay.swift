import CryptoKit
import Foundation
import JOSESwift

private final class ViewerSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func viewerAccessDenied(_ response: URLResponse?) -> Bool {
    guard let response = response as? HTTPURLResponse else { return false }
    if response.statusCode == 401 || response.statusCode == 403 { return true }
    guard (300..<400).contains(response.statusCode),
        let location = response.value(forHTTPHeaderField: "Location"),
        let url = URL(string: location, relativeTo: response.url)
    else { return false }
    return url.host?.lowercased().hasSuffix(".cloudflareaccess.com") == true
        || url.path.hasPrefix("/cdn-cgi/access/login")
}

@MainActor
final class Relay {
    private let base: URL
    private let credentials: ViewerAccessCredentials?
    private let session: URLSession
    private let room: String
    private let writer: String
    private let key: CryptoKit.SymmetricKey
    let viewerURL: URL
    private var socket: URLSessionWebSocketTask?
    private var sequence = 0
    private var controlsSequence = 0
    private var closed = false
    private var latest: ViewState?
    private var sendTask: Task<Void, Never>?
    private struct Publication {
        let packet: String
        let controls: Bool
    }
    private var pending: [Publication] = []
    private var pendingBytes = 0
    private var readers: Set<String> = []
    private var acknowledgments: [String: Int] = [:]
    private var publisher: String?
    private var selections: [String: Int] = [:]
    var onConnection: ((Bool, Int, Int) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onSelection: ((String, ViewerSelectionRequest) -> Void)?

    private init(
        base: URL, credentials: ViewerAccessCredentials?, session: URLSession,
        room: String, writer: String, reader: String
    ) {
        self.base = base
        self.credentials = credentials
        self.session = session
        self.room = room
        self.writer = writer
        key = CryptoKit.SymmetricKey(size: .bits256)
        var viewer = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        viewer.path = "/"
        viewer.query = nil
        viewer.fragment =
            "\(room).\(reader).\(key.withUnsafeBytes { Data($0) }.base64URLEncodedString())"
        viewerURL = viewer.url!
    }
    deinit { session.invalidateAndCancel() }

    static func create(url: String, credentials: ViewerAccessCredentials? = nil) async throws
        -> Relay
    {
        let endpoint = try ViewerEndpoint(url)
        try credentials?.validate(for: endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration, delegate: ViewerSessionDelegate(), delegateQueue: nil)
        do {
            var request = request(
                endpoint.url.appendingPathComponent("rooms"), credentials: credentials)
            request.httpMethod = "POST"
            let (data, response) = try await session.data(for: request)
            if viewerAccessDenied(response) { throw ViewerFailure.accessDenied }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
                let room = json["id"], let writer = json["writer"], let reader = json["reader"],
                UUID(uuidString: room) != nil, Data(base64URLEncoded: writer)?.count == 32,
                Data(base64URLEncoded: reader)?.count == 32
            else { throw ViewerFailure.generic }
            let relay = Relay(
                base: endpoint.url, credentials: credentials, session: session,
                room: room, writer: writer, reader: reader)
            do {
                try await relay.connect()
                return relay
            } catch {
                // Room deletion still runs if startup itself was cancelled.
                await Task { try? await relay.close() }.value
                throw error
            }
        } catch {
            session.invalidateAndCancel()
            if error is ViewerFailure || Task.isCancelled || error is CancellationError {
                throw error
            }
            throw ViewerFailure.generic
        }
    }

    private static func request(_ url: URL, credentials: ViewerAccessCredentials?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        if let credentials {
            request.setValue(credentials.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(
                credentials.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return request
    }
    private func connect() async throws {
        var endpoint = URLComponents(
            url: base.appendingPathComponent("rooms/\(room)/socket"), resolvingAgainstBaseURL: false
        )!
        endpoint.scheme = base.scheme == "https" ? "wss" : "ws"
        var request = Self.request(endpoint.url!, credentials: credentials)
        request.setValue(
            "skill-issue, skill-issue.writer.\(writer)",
            forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let next = session.webSocketTask(with: request)
        next.resume()
        // URLSession's WebSocket receive does not cancel with its awaiting Task.
        // Bound the ready handshake too: an upgraded but silent server can wait forever.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            next.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        do {
            let message = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await next.receive()
            } onCancel: {
                next.cancel(with: .goingAway, reason: nil)
            }
            try Task.checkCancellation()
            guard case .string(let text) = message,
                let ready = try JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any], ready["type"] as? String == "ready",
                let client = ready["client"] as? String, UUID(uuidString: client) != nil, !closed
            else { throw AppFailure.failed }
            socket = next
            publisher = client
            readers = []
            acknowledgments = [:]
            selections = [:]
            onConnection?(true, 0, 0)
            if let latest { try publish(latest) }
        } catch {
            next.cancel(with: .goingAway, reason: nil)
            if !closed && !Task.isCancelled {
                if viewerAccessDenied(next.response) { throw ViewerFailure.accessDenied }
                if next.response == nil {
                    // A rejected upgrade can hide its HTTP response from URLSession.
                    // Probe only the same origin, never the room or its secret link.
                    var check = Self.request(base, credentials: credentials)
                    check.timeoutInterval = 5
                    if let (_, response) = try? await session.data(for: check),
                        !closed, !Task.isCancelled, viewerAccessDenied(response)
                    {
                        throw ViewerFailure.accessDenied
                    }
                }
            }
            throw error
        }
    }
    // Calling publish is synchronous on MainActor. Every explicit key press is
    // queued in order; periodic snapshots cannot coalesce away scroll commands.
    func publish(_ state: ViewState) throws {
        sequence += 1
        let packet = try encryptedPacket(state, room: room, sequence: sequence, key: key)
        let controlsChanged =
            latest?.selection != state.selection || latest?.selectedID != state.selectedID
            || latest?.fontSize != state.fontSize || latest?.command != state.command
        if controlsChanged { controlsSequence = sequence }
        latest = state
        guard let socket else { return }
        if controlsChanged { connectionChanged() }
        if !controlsChanged, let last = pending.last, !last.controls {
            pendingBytes -= last.packet.utf8.count
            pending.removeLast()
        }
        pending.append(Publication(packet: packet, controls: controlsChanged))
        pendingBytes += packet.utf8.count
        // One packet can be in flight; retain at most two maximum packets behind it.
        // If explicit controls outpace the connection too, reconnect with the latest
        // state rather than dropping queued controls on an apparently healthy socket.
        guard pendingBytes <= maximumPacket * 2 else {
            connectionLost()
            return
        }
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            defer {
                // A cancelled old sender must not clear the replacement connection.
                if self?.socket === socket { self?.sendTask = nil }
            }
            while let self, !self.closed, !Task.isCancelled, self.socket === socket,
                !self.pending.isEmpty
            {
                let next = self.pending.removeFirst()
                self.pendingBytes -= next.packet.utf8.count
                do { try await socket.send(.string(next.packet)) } catch {
                    if self.socket === socket { self.connectionLost() }
                    return
                }
            }
        }
    }
    private func cancelSending() {
        sendTask?.cancel()
        sendTask = nil
        pending = []
        pendingBytes = 0
    }
    private func connectionLost() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        publisher = nil
        cancelSending()
        readers = []
        acknowledgments = [:]
        selections = [:]
        onConnection?(false, 0, 0)
    }
    func monitor() async {
        while !closed && !Task.isCancelled {
            do {
                if socket == nil { try await connect() }
                guard let socket else { continue }
                let message = try await socket.receive()
                guard self.socket === socket else { continue }
                guard case .string(let text) = message,
                    let body = try JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any]
                else { continue }
                if body["type"] as? String == "peers", let ids = body["readers"] as? [String] {
                    readers = Set(ids)
                    acknowledgments = acknowledgments.filter { readers.contains($0.key) }
                    selections = selections.filter { readers.contains($0.key) }
                    connectionChanged()
                }
                if body["type"] as? String == "ack" { try? acceptAcknowledgment(body) }
                if body["type"] as? String == "select" { try? acceptSelection(Data(text.utf8)) }
            } catch {
                connectionLost()
                if !closed && !Task.isCancelled, (error as? ViewerFailure)?.stopsSession == true {
                    onFailure?(error)
                    return
                }
                if !closed && !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }
    private func acceptSelection(_ data: Data) throws {
        struct Envelope: Decodable {
            let client: String
            let publisher: String
            let id: Int
            let box: String
        }
        struct Selection: Decodable { let answerID: String }
        let request = try JSONDecoder().decode(Envelope.self, from: data)
        guard request.publisher == publisher, readers.contains(request.client),
            request.id > (selections[request.client] ?? 0), request.id <= 9_007_199_254_740_991,
            request.box.utf8.count <= 1024, let bytes = Data(base64Encoded: request.box)
        else { return }
        let box = try AES.GCM.SealedBox(combined: bytes)
        let plain = try AES.GCM.open(
            box, using: key,
            authenticating: Data(
                "\(room):select:\(request.client):\(request.publisher):\(request.id)".utf8))
        let selection = try JSONDecoder().decode(Selection.self, from: plain)
        selections[request.client] = request.id
        onSelection?(
            selection.answerID, ViewerSelectionRequest(client: request.client, id: request.id))
    }
    private func acceptAcknowledgment(_ body: [String: Any]) throws {
        guard let client = body["client"] as? String, readers.contains(client),
            let seq = body["seq"] as? Int, seq > 0, seq <= sequence,
            let raw = body["box"] as? String, raw.count < 1024, let data = Data(base64Encoded: raw)
        else { return }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(
            box, using: key, authenticating: Data("\(room):ack:\(client):\(seq)".utf8))
        guard let ack = try JSONSerialization.jsonObject(with: plain) as? [String: Int],
            ack["seq"] == seq, let command = ack["command"], command >= 0,
            command == (latest?.command?.id ?? 0)
        else { return }
        // History and zoom need their snapshot applied too. A current scroll
        // command alone cannot confirm an older selection or font size.
        acknowledgments[client] = max(acknowledgments[client] ?? 0, seq)
        connectionChanged()
    }
    private func connectionChanged() {
        onConnection?(
            socket != nil, readers.count,
            acknowledgments.values.filter { $0 >= controlsSequence }.count)
    }
    func close() async throws {
        guard !closed else { return }
        closed = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        publisher = nil
        selections = [:]
        cancelSending()
        defer { session.invalidateAndCancel() }
        var request = Self.request(
            base.appendingPathComponent("rooms/\(room)/end"), credentials: credentials)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(writer)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        if viewerAccessDenied(response) { throw ViewerFailure.accessDenied }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ViewerFailure.generic }
    }
}
