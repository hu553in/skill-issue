import CryptoKit
import Foundation

@main enum NativeRelayCheck {
    struct Ready: Decodable {
        let type: String
        let client: String
    }
    struct Packet: Codable {
        let type: String
        let seq: Int
        let box: String
    }
    struct Fixture: Encodable {
        let room: String
        let viewerURL: String
        let packet: Packet
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw AppFailure.failed }
        let relay = try await Relay.create(url: CommandLine.arguments[1])
        do {
            try await check(relay, fixtureURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            try await relay.close()
        } catch {
            try? await relay.close()
            throw error
        }
    }

    @MainActor static func check(_ relay: Relay, fixtureURL: URL) async throws {
        guard let fragment = relay.viewerURL.fragment else { throw AppFailure.failed }
        let parts = fragment.split(separator: ".").map(String.init)
        guard parts.count == 3,
            var endpoint = URLComponents(url: relay.viewerURL, resolvingAgainstBaseURL: false),
            let keyData = Data(base64url: parts[2])
        else { throw AppFailure.failed }
        endpoint.fragment = nil
        endpoint.path = "/rooms/\(parts[0])/socket"
        endpoint.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        guard let socketURL = endpoint.url else { throw AppFailure.failed }
        let socket = URLSession.shared.webSocketTask(with: socketURL)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await socket.send(
            .string("{\"type\":\"auth\",\"role\":\"reader\",\"token\":\"\(parts[1])\"}"))
        guard case .string(let rawReady) = try await socket.receive() else {
            throw AppFailure.failed
        }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(rawReady.utf8))
        guard ready.type == "ready", !ready.client.isEmpty else { throw AppFailure.failed }
        var appliedViewers = 0
        relay.onConnection = { _, count in appliedViewers = count }
        let monitor = Task { await relay.monitor() }
        defer { monitor.cancel() }
        let state = ViewState(
            live: true,
            answers: [
                AnswerCard(
                    id: "a", text: "Use a hash map. Average lookup is O(1).", status: "complete")
            ],
            selectedID: "a",
            command: ViewerCommand(id: 3, answerID: "a", direction: 1)
        )
        try relay.publish(state)
        guard case .string(let rawPacket) = try await socket.receive() else {
            throw AppFailure.failed
        }
        let packet = try JSONDecoder().decode(Packet.self, from: Data(rawPacket.utf8))
        guard packet.type == "state", packet.seq == 1,
            let combined = Data(base64Encoded: packet.box)
        else { throw AppFailure.failed }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(
            box, using: SymmetricKey(data: keyData),
            authenticating: Data("\(parts[0]):\(packet.seq)".utf8))
        guard try JSONDecoder().decode(ViewState.self, from: plain) == state else {
            throw AppFailure.failed
        }
        let fixture = Fixture(
            room: parts[0], viewerURL: relay.viewerURL.absoluteString, packet: packet)
        try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
        // The TypeScript reader must decrypt this packet and acknowledge its command.
        // This native reader intentionally sends no ACK, so it cannot satisfy the check.
        for _ in 0..<500 {
            if appliedViewers == 1 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppFailure.failed
    }
}
