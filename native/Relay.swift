import CryptoKit
import Foundation

@MainActor
final class Relay {
    private let base: URL
    private let room: String
    private let writer: String
    private let key: SymmetricKey
    let viewerURL: URL
    private var socket: URLSessionWebSocketTask?
    private var sequence = 0
    private var closed = false
    private var latest: ViewState?
    private var sendTask: Task<Void, Never>?
    private var readers: Set<String> = []
    private var acknowledgments: [String: Int] = [:]
    var onConnection: ((Bool, Int) -> Void)?

    private init(base: URL, room: String, writer: String, reader: String) {
        self.base = base
        self.room = room
        self.writer = writer
        key = SymmetricKey(size: .bits256)
        var viewer = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        viewer.path = "/"
        viewer.query = nil
        viewer.fragment = "\(room).\(reader).\(key.withUnsafeBytes { Data($0) }.base64url)"
        viewerURL = viewer.url!
    }
    static func create(url: String) async throws -> Relay {
        guard let base = URL(string: url), base.host != nil, base.path.isEmpty || base.path == "/",
            base.query == nil, base.fragment == nil,
            base.scheme == "https"
                || base.scheme == "http" && ["127.0.0.1", "localhost"].contains(base.host ?? "")
        else { throw AppFailure.failed }
        var request = URLRequest(url: base.appendingPathComponent("rooms"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
            let room = json["id"], let writer = json["writer"], let reader = json["reader"],
            UUID(uuidString: room) != nil, Data(base64url: writer)?.count == 32,
            Data(base64url: reader)?.count == 32
        else { throw AppFailure.failed }
        let relay = Relay(base: base, room: room, writer: writer, reader: reader)
        do {
            try await relay.connect()
            return relay
        } catch {
            // Room deletion still runs if startup itself was cancelled.
            await Task { try? await relay.close() }.value
            throw error
        }
    }
    private func connect() async throws {
        var endpoint = URLComponents(
            url: base.appendingPathComponent("rooms/\(room)/socket"), resolvingAgainstBaseURL: false
        )!
        endpoint.scheme = base.scheme == "https" ? "wss" : "ws"
        let next = URLSession.shared.webSocketTask(with: endpoint.url!)
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
                try await next.send(
                    .string("{\"type\":\"auth\",\"role\":\"writer\",\"token\":\"\(writer)\"}"))
                return try await next.receive()
            } onCancel: {
                next.cancel(with: .goingAway, reason: nil)
            }
            try Task.checkCancellation()
            guard case .string(let text) = message,
                let ready = try JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any], ready["type"] as? String == "ready", !closed
            else { throw AppFailure.failed }
            socket = next
            readers = []
            acknowledgments = [:]
            onConnection?(true, 0)
            if let latest { try publish(latest) }
        } catch {
            next.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }
    // Calling publish is synchronous on MainActor. Every explicit key press is
    // queued in order; periodic snapshots cannot coalesce away scroll commands.
    func publish(_ state: ViewState) throws {
        sequence += 1
        let packet = try encryptedPacket(state, room: room, sequence: sequence, key: key)
        latest = state
        guard let socket else { return }
        let previous = sendTask
        sendTask = Task { [weak self] in
            await previous?.value
            guard let self, !self.closed, self.socket === socket else { return }
            do { try await socket.send(.string(packet)) } catch {
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
    func monitor() async {
        while !closed && !Task.isCancelled {
            do {
                if socket == nil { try await connect() }
                guard let socket else { continue }
                let message = try await socket.receive()
                guard case .string(let text) = message,
                    let body = try JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any]
                else { continue }
                if body["type"] as? String == "peers", let ids = body["readers"] as? [String] {
                    readers = Set(ids)
                    acknowledgments = acknowledgments.filter { readers.contains($0.key) }
                    connectionChanged()
                }
                if body["type"] as? String == "ack" { try? acceptAcknowledgment(body) }
            } catch {
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                readers = []
                acknowledgments = [:]
                onConnection?(false, 0)
                if !closed && !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
            }
        }
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
            command <= (latest?.command?.id ?? 0)
        else { return }
        acknowledgments[client] = max(acknowledgments[client] ?? 0, command)
        connectionChanged()
    }
    private func connectionChanged() {
        let current = latest?.command?.id ?? 0
        onConnection?(socket != nil, acknowledgments.values.filter { $0 >= current }.count)
    }
    func close() async throws {
        closed = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        sendTask?.cancel()
        var request = URLRequest(url: base.appendingPathComponent("rooms/\(room)/end"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(writer)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.failed }
    }
}
