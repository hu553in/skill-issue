import CryptoKit
import Foundation
@preconcurrency import Network
import Testing

@testable import SkillIssue

private struct WebSocketFrames: Sendable {
    private var buffer = Data()
    private var fragment = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while buffer.count >= 2 {
            let bytes = Array(buffer.prefix(14))
            let length = Int(bytes[1] & 0x7F)
            var offset = length == 126 ? 4 : length == 127 ? 10 : 2
            guard bytes.count >= offset else { break }
            let sizeValue =
                length < 126
                ? UInt64(length)
                : bytes[2..<offset].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard sizeValue <= UInt64(maximumPacket), bytes[1] & 0x80 != 0 else {
                throw AppFailure.failed
            }
            let size = Int(sizeValue)
            guard buffer.count >= offset + 4 + size else { break }
            let mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
            let opcode = bytes[0] & 0x0F
            if opcode == 1 || opcode == 0 {
                let start = buffer.startIndex + offset
                var payload = buffer.subdata(in: start..<(start + size))
                payload.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for index in bytes.indices { bytes[index] ^= mask[index & 3] }
                }
                fragment.append(payload)
                guard fragment.count <= maximumPacket else { throw AppFailure.failed }
                if bytes[0] & 0x80 != 0 {
                    messages.append(fragment)
                    fragment = Data()
                }
            }
            buffer.removeFirst(offset + size)
        }
        return messages
    }
}

@MainActor
private final class TestRelay {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
    }
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var sockets: [NWConnection] = []
    private var draining: Set<ObjectIdentifier> = []
    struct Publication {
        let connection: Int
        let data: Data
    }
    private(set) var publications: [Publication] = []
    private var readPublications = false
    private var ready: CheckedContinuation<String, Error>?
    private(set) var upgraded = false
    private(set) var deletions = 0
    private(set) var requests: [Request] = []
    var createStatus = 200
    var socketStatus = 101
    var rootStatus = 200
    var deletionStatus = 200
    var redirect: String?
    var silent = false
    var dropCreation = false
    var creationBody: String?
    var readyMessage = "{\"type\":\"ready\"}"
    static let token = String(repeating: "a", count: 43)
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
    func disconnect() {
        for socket in sockets { socket.cancel() }
        sockets = []
    }
    func drainPublications() {
        readPublications = true
        for socket in sockets { drain(socket) }
    }
    private func drain(_ connection: NWConnection) {
        guard draining.insert(ObjectIdentifier(connection)).inserted else { return }
        readFrames(connection, frames: WebSocketFrames())
    }
    private func readFrames(_ connection: NWConnection, frames: WebSocketFrames) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) {
            [weak self] data, _, complete, error in
            guard error == nil else { return }
            let parsed = Task.detached {
                var next = frames
                let messages = try next.append(data ?? Data())
                return (next, messages)
            }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let (next, messages) = try await parsed.value
                    guard let index = self.sockets.firstIndex(where: { $0 === connection }) else {
                        return
                    }
                    self.publications.append(
                        contentsOf: messages.map {
                            Publication(connection: index, data: $0)
                        })
                    if !complete { self.readFrames(connection, frames: next) }
                } catch {
                    Issue.record(error)
                    connection.cancel()
                }
            }
        }
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
                let lines = text.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2 else {
                    connection.cancel()
                    return
                }
                let headers = Dictionary(
                    lines.dropFirst().compactMap { line -> (String, String)? in
                        let pair = line.split(separator: ":", maxSplits: 1)
                        guard pair.count == 2 else { return nil }
                        return (
                            pair[0].lowercased(), pair[1].trimmingCharacters(in: .whitespaces)
                        )
                    }, uniquingKeysWith: { _, last in last })
                let request = Request(
                    method: String(first[0]), path: String(first[1]), headers: headers)
                self.requests.append(request)
                if request.path == "/rooms" && self.dropCreation {
                    connection.cancel()
                    return
                }
                if request.path.hasSuffix("/socket") && self.socketStatus == 101 {
                    let key = text.components(separatedBy: "\r\n").first {
                        $0.lowercased().hasPrefix("sec-websocket-key:")
                    }!.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                    let accept = Data(
                        Insecure.SHA1.hash(
                            data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                    ).base64EncodedString()
                    let response =
                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: skill-issue\r\n\r\n"
                    var data = Data(response.utf8)
                    if !self.silent {
                        let message = Data(self.readyMessage.utf8)
                        data.append(contentsOf: [0x81, UInt8(message.count)])
                        data.append(message)
                    }
                    connection.send(
                        content: data, completion: .contentProcessed { _ in })
                    self.upgraded = true
                    self.sockets.append(connection)
                    if self.readPublications { self.drain(connection) }
                } else {
                    let body: String
                    let status: Int
                    if request.path == "/rooms" {
                        status = self.createStatus
                        body =
                            self.creationBody
                            ?? "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"writer\":\"\(Self.token)\",\"reader\":\"\(Self.token)\"}"
                    } else if request.path.hasSuffix("/end") {
                        status = self.deletionStatus
                        self.deletions += 1
                        body = "OK"
                    } else {
                        status =
                            request.path.hasSuffix("/socket") ? self.socketStatus : self.rootStatus
                        body = "Error"
                    }
                    let location = self.redirect.map { "Location: \($0)\r\n" } ?? ""
                    let response =
                        "HTTP/1.1 \(status) Response\r\nContent-Length: \(body.utf8.count)\r\nSet-Cookie: CF_Authorization=response-cookie; Path=/\r\n\(location)Connection: close\r\n\r\n\(body)"
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
        let server = try TestRelay()
        server.silent = true
        let base = try await server.start()
        defer { server.stop() }
        var finished = false
        var failed = false
        var failure: Error?
        let task = Task {
            do {
                let relay = try await Relay.create(url: base)
                try await relay.close()
            } catch {
                failed = true
                failure = error
            }
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
        if cancel {
            #expect(!(failure is ViewerFailure))
        } else {
            #expect(failure as? ViewerFailure == .generic)
        }
        #expect(server.deletions == 1)
    }
}

@MainActor
@Test func relayStartupFailuresOfferViewerRecoveryWithoutLeakingCreatedRooms() async throws {
    for stage in ["network", "json", "handshake"] {
        let server = try TestRelay()
        server.dropCreation = stage == "network"
        server.creationBody = stage == "json" ? "not JSON" : nil
        if stage == "handshake" { server.readyMessage = "{\"type\":\"wrong\"}" }
        let base = try await server.start()
        defer { server.stop() }
        await #expect(throws: ViewerFailure.generic) { _ = try await Relay.create(url: base) }
        #expect(!server.requests.isEmpty)
        #expect(server.deletions == (stage == "handshake" ? 1 : 0))
    }
}

@MainActor
@Test func relayAccessHeadersStayOutOfLinksAndCookiesAcrossTheWholeLifecycle() async throws {
    for useAccess in [false, true] {
        let server = try TestRelay()
        let base = try await server.start()
        defer { server.stop() }
        let credentials =
            useAccess
            ? ViewerAccessCredentials(
                origin: base, clientID: "test-client.access", clientSecret: "test-secret")
            : nil
        let relay = try await Relay.create(url: base, credentials: credentials)
        #expect(!relay.viewerURL.absoluteString.contains("test-client"))
        #expect(!relay.viewerURL.absoluteString.contains("test-secret"))
        #expect(relay.viewerURL.query == nil && relay.viewerURL.user == nil)
        let monitor = Task { await relay.monitor() }
        defer { monitor.cancel() }
        server.disconnect()
        let deadline = ContinuousClock.now + .seconds(5)
        while server.requests.filter({ $0.path.hasSuffix("/socket") }).count < 2,
            ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        try #require(server.requests.filter({ $0.path.hasSuffix("/socket") }).count == 2)
        try await relay.close()
        await monitor.value
        #expect(server.deletions == 1)
        #expect(server.requests.first?.method == "POST")
        #expect(server.requests.last?.path.hasSuffix("/end") == true)
        #expect(server.requests.last?.headers["authorization"] == "Bearer \(TestRelay.token)")
        for request in server.requests {
            #expect(request.headers["cf-access-client-id"] == credentials?.clientID)
            #expect(request.headers["cf-access-client-secret"] == credentials?.clientSecret)
            #expect(request.headers["cookie"] == nil)
            #expect(!request.path.contains("test-secret") && !request.path.contains("test-client"))
            if request.path.hasSuffix("/socket") {
                #expect(
                    request.headers["sec-websocket-protocol"]?.contains(
                        "skill-issue.writer.\(TestRelay.token)") == true)
                #expect(request.headers["authorization"] == nil)
            }
        }
    }
}

@MainActor
@Test func relayRejectsMismatchedCredentialsBeforeMakingARequest() async throws {
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    let credentials = ViewerAccessCredentials(
        origin: "https://other.example.invalid", clientID: "test-client",
        clientSecret: "test-secret")
    await #expect(throws: ViewerFailure.setupRequired) {
        _ = try await Relay.create(url: base, credentials: credentials)
    }
    #expect(server.requests.isEmpty)
}

@MainActor
@Test func relayCreationClassifiesAccessRefusalsAndKeepsServerFailuresTransient() async throws {
    for status in [401, 403, 302, 500] {
        let server = try TestRelay()
        server.createStatus = status
        server.redirect = "https://test-team.cloudflareaccess.com/cdn-cgi/access/login/test"
        let base = try await server.start()
        defer { server.stop() }
        let credentials = ViewerAccessCredentials(
            origin: base, clientID: "test-client", clientSecret: "test-secret")
        await #expect(throws: status == 500 ? ViewerFailure.generic : ViewerFailure.accessDenied) {
            _ = try await Relay.create(url: base, credentials: credentials)
        }
        #expect(server.requests.count == 1)
    }
}

@MainActor
@Test func relayDoesNotFollowCrossOriginHTTPOrWebSocketRedirects() async throws {
    let destination = try TestRelay()
    let other = try await destination.start()
    defer { destination.stop() }
    for (upgrade, location) in [
        (false, other), (true, other),
        (true, other.replacingOccurrences(of: "http://", with: "ws://")),
    ] {
        let server = try TestRelay()
        server.redirect = location
        if upgrade { server.socketStatus = 302 } else { server.createStatus = 302 }
        let base = try await server.start()
        defer { server.stop() }
        let credentials = ViewerAccessCredentials(
            origin: base, clientID: "test-client", clientSecret: "test-secret")
        await #expect(throws: (any Error).self) {
            _ = try await Relay.create(url: base, credentials: credentials)
        }
        #expect(destination.requests.isEmpty)
        #expect(!upgrade || server.deletions == 1)
    }
}

@MainActor
@Test func relayStopsItsMonitorOnConfirmedAccessDenialAfterReconnect() async throws {
    for status in [401, 403, 302] {
        let server = try TestRelay()
        let base = try await server.start()
        defer { server.stop() }
        let credentials = ViewerAccessCredentials(
            origin: base, clientID: "test-client", clientSecret: "test-secret")
        let relay = try await Relay.create(url: base, credentials: credentials)
        var failures: [ViewerFailure] = []
        relay.onFailure = { error in
            if let failure = error as? ViewerFailure { failures.append(failure) }
        }
        let monitor = Task { await relay.monitor() }
        defer { monitor.cancel() }
        server.socketStatus = status
        server.rootStatus = status
        server.redirect = "https://test-team.cloudflareaccess.com/cdn-cgi/access/login/test"
        server.disconnect()
        let deadline = ContinuousClock.now + .seconds(7)
        while failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(failures == [.accessDenied])
        await monitor.value
        let attempts = server.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requests.count == attempts)
        try await relay.close()
    }
}

@MainActor
@Test func relayReconnectsAfterAServerFailureWithoutReportingAccessDenial() async throws {
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    let credentials = ViewerAccessCredentials(
        origin: base, clientID: "test-client", clientSecret: "test-secret")
    let relay = try await Relay.create(url: base, credentials: credentials)
    var failures = 0
    var reconnected = false
    relay.onFailure = { _ in failures += 1 }
    relay.onConnection = { connected, _, _ in if connected { reconnected = true } }
    let monitor = Task { await relay.monitor() }
    defer { monitor.cancel() }
    server.socketStatus = 500
    server.disconnect()
    let deadline = ContinuousClock.now + .seconds(7)
    while server.requests.filter({ $0.path.hasSuffix("/socket") }).count < 2,
        ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(server.requests.filter({ $0.path.hasSuffix("/socket") }).count == 2)
    #expect(failures == 0)
    server.socketStatus = 101
    while !reconnected, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(reconnected)
    #expect(failures == 0)
    try await relay.close()
    await monitor.value
}

@MainActor
@Test func relayDeletionStillUsesWriterAuthorizationWhenAccessWasRevoked() async throws {
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    let credentials = ViewerAccessCredentials(
        origin: base, clientID: "test-client", clientSecret: "test-secret")
    let relay = try await Relay.create(url: base, credentials: credentials)
    server.deletionStatus = 403
    await #expect(throws: ViewerFailure.accessDenied) { try await relay.close() }
    try await relay.close()
    #expect(server.deletions == 1)
    let request = try #require(server.requests.last)
    #expect(request.headers["authorization"] == "Bearer \(TestRelay.token)")
    #expect(request.headers["cf-access-client-id"] == credentials.clientID)
    #expect(request.headers["cf-access-client-secret"] == credentials.clientSecret)
}

private func publication(
    _ received: TestRelay.Publication, viewer: URL
) throws -> (sequence: Int, state: ViewState) {
    struct Packet: Decodable { let seq: Int, box: String }
    let fragment = try #require(viewer.fragment).split(separator: ".").map(String.init)
    let key = try #require(
        Data(
            base64Encoded:
                fragment[2].replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="))
    let packet = try JSONDecoder().decode(Packet.self, from: received.data)
    let data = try #require(Data(base64Encoded: packet.box))
    let plaintext = try AES.GCM.open(
        AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key),
        authenticating: Data("\(fragment[0]):\(packet.seq)".utf8))
    return (packet.seq, try JSONDecoder().decode(ViewState.self, from: plaintext))
}

@MainActor
@Test func slowRelayCoalescesUnsentStreamingSnapshotsAndDeliversTheNewestText() async throws {
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    let relay = try await Relay.create(url: base)
    var state = ViewState(
        live: true,
        answers: [AnswerCard(id: "a", text: String(repeating: "x", count: 2_000_000))],
        selectedID: "a")
    for index in 1...25 {
        state.answers[0].text += "\(index)"
        try relay.publish(state)
        try await Task.sleep(for: .milliseconds(index <= 5 ? 150 : 25))
    }
    server.drainPublications()
    let deadline = ContinuousClock.now + .seconds(7)
    while try server.publications.last.map({
        try publication($0, viewer: relay.viewerURL).sequence
    }) != 25, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let received = try server.publications.map { try publication($0, viewer: relay.viewerURL) }
    try #require(received.last?.sequence == 25)
    #expect(received.last?.state.answers[0].text == state.answers[0].text)
    #expect(received.count < 25)
    #expect(received.map(\.sequence) == received.map(\.sequence).sorted())
    try await relay.close()
}

@MainActor
@Test func coalescingStreamingSnapshotsNeverDropsOrReordersExplicitControls() async throws {
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    server.drainPublications()
    let relay = try await Relay.create(url: base)
    var state = ViewState(
        live: true, answers: [AnswerCard(id: "a", text: "initial")], selectedID: "a")
    try relay.publish(state)
    for _ in 1...6 {
        state.scroll(1)
        try relay.publish(state)
        state.answers[0].text += "|first"
        try relay.publish(state)
        state.answers[0].text += "|second"
        try relay.publish(state)
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while try server.publications.last.map({
        try publication($0, viewer: relay.viewerURL).sequence
    }) != 19, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let received = try server.publications.map { try publication($0, viewer: relay.viewerURL) }
    try #require(received.last?.sequence == 19)
    var controls: [Int] = []
    for packet in received {
        if let command = packet.state.command, controls.last != command.id {
            controls.append(command.id)
            #expect(command.direction == 1 && command.answerID == "a")
        }
    }
    #expect(controls == [1, 2, 3, 4, 5, 6])
    #expect(
        received.last?.state.answers[0].text == "initial"
            + String(repeating: "|first|second", count: 6))
    #expect(received.map(\.sequence) == received.map(\.sequence).sorted())
    try await relay.close()
}

@MainActor
@Test func overloadedControlsReconnectWithOnlyTheLatestStateAndKeepTheNewSenderUsable()
    async throws
{
    let server = try TestRelay()
    let base = try await server.start()
    defer { server.stop() }
    let relay = try await Relay.create(url: base)
    var connected: [Bool] = []
    var failures = 0
    relay.onConnection = { online, _, _ in connected.append(online) }
    relay.onFailure = { _ in failures += 1 }
    let monitor = Task { await relay.monitor() }
    defer { monitor.cancel() }
    var state = ViewState(
        live: true,
        answers: [AnswerCard(id: "a", text: String(repeating: "x", count: 2_000_000))],
        selectedID: "a")
    try relay.publish(state)
    try await Task.sleep(for: .milliseconds(150))
    for _ in 1...6 {
        state.scroll(1)
        try relay.publish(state)
    }
    #expect(connected.contains(false))
    server.drainPublications()
    let deadline = ContinuousClock.now + .seconds(7)
    while !server.publications.contains(where: { $0.connection > 0 }),
        ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    let replacement = try #require(server.publications.first { $0.connection > 0 })
    let replay = try publication(replacement, viewer: relay.viewerURL)
    #expect(replay.sequence == 8 && replay.state.command?.id == 6)
    #expect(replay.state.answers[0].text == state.answers[0].text && failures == 0)
    state.answers[0].text += "new sender remains usable"
    try relay.publish(state)
    while try server.publications.last.map({
        try publication($0, viewer: relay.viewerURL).sequence
    }) != 9, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let newest = try publication(try #require(server.publications.last), viewer: relay.viewerURL)
    #expect(
        newest.sequence == 9 && newest.state.answers[0].text.hasSuffix("new sender remains usable"))
    #expect(failures == 0)
    try await relay.close()
    await monitor.value
}
