import CryptoKit
import Foundation
@preconcurrency import Network
import Testing

@testable import SkillIssue

// A real loopback server upgrades the socket but deliberately never sends ready.
@MainActor
private final class SilentRelay {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<String, Error>?
    private(set) var upgraded = false
    private(set) var deletions = 0
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.read(connection, buffer: Data())
            }
        }
        return try await withCheckedThrowingContinuation { ready in
            self.ready = ready
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ready = state, let port = self.listener.port {
                        self.ready?.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                        self.ready = nil
                    } else if case .failed(let error) = state {
                        self.ready?.resume(throwing: error)
                        self.ready = nil
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else {
                    connection.cancel()
                    return
                }
                let buffer = buffer + (data ?? Data())
                let text = String(decoding: buffer, as: UTF8.self)
                guard text.contains("\r\n\r\n") else {
                    if complete {
                        connection.cancel()
                    } else {
                        self.read(connection, buffer: buffer)
                    }
                    return
                }
                if text.hasPrefix("GET /rooms/") {
                    let key = text.components(separatedBy: "\r\n").first {
                        $0.lowercased().hasPrefix("sec-websocket-key:")
                    }!.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                    let accept = Data(
                        Insecure.SHA1.hash(
                            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                    ).base64EncodedString()
                    let response =
                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                    connection.send(
                        content: Data(response.utf8), completion: .contentProcessed { _ in })
                    self.upgraded = true
                } else {
                    let body: String
                    if text.hasPrefix("POST /rooms ") {
                        let token = String(repeating: "a", count: 43)
                        body =
                            "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"writer\":\"\(token)\",\"reader\":\"\(token)\"}"
                    } else {
                        self.deletions += 1
                        body = "OK"
                    }
                    let response =
                        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: Data(response.utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}

@MainActor
@Test func silentRelayHandshakeCancelsAndTimesOutWithoutLeakingRoom() async throws {
    for cancel in [true, false] {
        let server = try SilentRelay()
        let base = try await server.start()
        defer { server.stop() }
        var finished = false
        var failed = false
        let task = Task {
            do {
                let relay = try await Relay.create(url: base)
                try await relay.close()
            } catch { failed = true }
            finished = true
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(cancel ? 3 : 20)
        while !server.upgraded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(server.upgraded)
        if cancel { task.cancel() }
        while !finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished)
        #expect(failed)
        #expect(server.deletions == 1)
    }
}
