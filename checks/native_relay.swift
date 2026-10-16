import CryptoKit
import Foundation
import JOSESwift

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
        var stage = "published"
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
            let keyData = Data(base64URLEncoded: parts[2])
        else { throw AppFailure.failed }
        endpoint.fragment = nil
        endpoint.path = "/rooms/\(parts[0])/socket"
        endpoint.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        guard let socketURL = endpoint.url else { throw AppFailure.failed }
        var connected = false
        var viewerCount = 0
        var appliedCount = 0
        var connectionCounts: [Int] = []
        relay.onConnection = { online, count, applied in
            connected = online
            viewerCount = count
            appliedCount = applied
            connectionCounts.append(count)
        }
        let monitor = Task { await relay.monitor() }
        defer { monitor.cancel() }
        let socket = URLSession.shared.webSocketTask(
            with: socketURL, protocols: ["skill-issue", "skill-issue.reader.\(parts[1])"])
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        guard case .string(let rawReady) = try await socket.receive() else {
            throw AppFailure.failed
        }
        let ready = try JSONDecoder().decode(Ready.self, from: Data(rawReady.utf8))
        guard ready.type == "ready", !ready.client.isEmpty else { throw AppFailure.failed }
        try await wait { connected && viewerCount == 1 }
        // Transport presence does not require applying or acknowledging a snapshot.
        guard appliedCount == 0 else { throw AppFailure.failed }
        connectionCounts = []
        var state = ViewState(
            live: true,
            answers: [
                AnswerCard(
                    id: "a", text: "Use a hash map. Average lookup is O(1).", status: "complete")
            ],
            selectedID: "a",
            command: ViewerCommand(id: 3, answerID: "a", direction: 1)
        )
        var selections: [ViewerSelectionRequest] = []
        var selectionError: Error?
        relay.onSelection = { answerID, request in
            guard state.select(answerID: answerID, request: request) else { return }
            selections.append(request)
            do { try relay.publish(state) } catch { selectionError = error }
        }
        try relay.publish(state)
        let (packet, received) = try await snapshot(socket, room: parts[0], key: keyData)
        guard packet.seq == 1, received == state, viewerCount == 1, appliedCount == 0 else {
            throw AppFailure.failed
        }
        func report(_ stage: String, packet: Packet) throws {
            let fixture = Fixture(
                room: parts[0], viewerURL: relay.viewerURL.absoluteString, packet: packet,
                stage: stage)
            try JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
        }
        try report("published", packet: packet)
        // The TypeScript reader must decrypt this packet and acknowledge its command.
        // This native reader intentionally sends no ACK, so it cannot satisfy the check.
        try await wait { viewerCount == 2 && appliedCount == 1 }

        var before = connectionCounts.count
        state.answers[0].text += " A streamed conclusion."
        state.answers.append(
            AnswerCard(id: "b", text: "Use a balanced tree.", status: "complete"))
        try relay.publish(state)
        let (streamed, streamedState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard streamed.seq == 2, streamedState == state, appliedCount == 1 else {
            throw AppFailure.failed
        }
        try relay.publish(state)
        let (heartbeat, heartbeatState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard heartbeat.seq == 3, heartbeatState == state, appliedCount == 1,
            connectionCounts.count == before
        else { throw AppFailure.failed }
        try report("non-controls-held", packet: heartbeat)
        // A valid duplicate ACK is an ordered barrier after the withheld snapshots.
        try await wait { connectionCounts.count > before }
        guard appliedCount == 1 else { throw AppFailure.failed }

        state.select(1)
        try relay.publish(state)
        guard appliedCount == 0 else { throw AppFailure.failed }
        let (history, historyState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard history.seq == 4, historyState == state else { throw AppFailure.failed }
        before = connectionCounts.count
        try report("history-pending", packet: history)
        // Forged and rebound ACKs precede a valid old ACK on the same reader socket.
        try await wait { connectionCounts.count > before }
        guard appliedCount == 0 else { throw AppFailure.failed }
        try report("history-stale-rejected", packet: history)
        try await wait { appliedCount == 1 }

        state.fontSize = 28
        try relay.publish(state)
        guard appliedCount == 0 else { throw AppFailure.failed }
        let (zoom, zoomState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard zoom.seq == 5, zoomState == state else { throw AppFailure.failed }
        before = connectionCounts.count
        try report("zoom-pending", packet: zoom)
        try await wait { connectionCounts.count >= before + 2 }
        guard appliedCount == 0 else { throw AppFailure.failed }
        try report("zoom-stale-rejected", packet: zoom)
        try await wait { appliedCount == 1 }
        before = connectionCounts.count
        try report("zoom-synced", packet: zoom)
        try await wait { connectionCounts.count > before }
        guard appliedCount == 1 else { throw AppFailure.failed }

        state.command = ViewerCommand(id: 4, answerID: "b", direction: -1)
        try relay.publish(state)
        guard appliedCount == 0 else { throw AppFailure.failed }
        let (scroll, scrollState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard scroll.seq == 6, scrollState == state else { throw AppFailure.failed }
        before = connectionCounts.count
        try report("scroll-pending", packet: scroll)
        try await wait { connectionCounts.count > before }
        guard appliedCount == 0 else { throw AppFailure.failed }
        try report("scroll-command-rejected", packet: scroll)
        try await wait { appliedCount == 1 }

        try report("selection-ready", packet: scroll)
        try await wait { selections.count == 1 }
        if let selectionError { throw selectionError }
        let (selected, selectedState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard selected.seq == 7, selectedState == state, state.selectedID == "a",
            state.selection == 2, state.selectionRequest?.id == 1
        else { throw AppFailure.failed }
        try await wait { appliedCount == 1 }

        state.select(1)
        try relay.publish(state)
        let (navigated, navigatedState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard navigated.seq == 8, navigatedState == state, state.selectedID == "b",
            state.selection == 3, state.selectionRequest == nil
        else { throw AppFailure.failed }
        try await wait { appliedCount == 1 }
        try report("selection-repeat-ready", packet: navigated)
        try await wait { selections.count == 2 }
        if let selectionError { throw selectionError }
        let (repeated, repeatedState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard repeated.seq == 9, repeatedState == state, state.selectedID == "b",
            state.selection == 4, state.selectionRequest?.id == 2
        else { throw AppFailure.failed }
        // The reader sends stale/duplicate selections before acknowledging this snapshot.
        try await wait { appliedCount == 1 }
        guard selections.map(\.id) == [1, 2], state.selectedID == "b", state.selection == 4
        else { throw AppFailure.failed }

        state.scroll(1)
        try relay.publish(state)
        guard viewerCount == 2, appliedCount == 0, connectionCounts.allSatisfy({ $0 > 0 }) else {
            throw AppFailure.failed
        }
        let (pending, pendingState) = try await snapshot(socket, room: parts[0], key: keyData)
        guard pending.seq == 10, pendingState == state else { throw AppFailure.failed }
        socket.cancel(with: .normalClosure, reason: nil)
        try await wait { viewerCount == 1 }
        guard connected, appliedCount == 0 else { throw AppFailure.failed }
        try report("native-reader-disconnected", packet: pending)
        try await wait { viewerCount == 0 }
        guard connected, appliedCount == 0 else { throw AppFailure.failed }
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw AppFailure.failed
    }

    @MainActor static func snapshot(_ socket: URLSessionWebSocketTask, room: String, key: Data)
        async throws -> (Packet, ViewState)
    {
        guard case .string(let rawPacket) = try await socket.receive() else {
            throw AppFailure.failed
        }
        let packet = try JSONDecoder().decode(Packet.self, from: Data(rawPacket.utf8))
        guard packet.type == "state", let combined = Data(base64Encoded: packet.box) else {
            throw AppFailure.failed
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(
            box, using: CryptoKit.SymmetricKey(data: key),
            authenticating: Data("\(room):\(packet.seq)".utf8))
        return (packet, try JSONDecoder().decode(ViewState.self, from: plain))
    }
}
