import AudioCommon
import CryptoKit
import Foundation
import JOSESwift
import Testing

@testable import SkillIssue

@Test func encryptedSnapshot() throws {
    let key = CryptoKit.SymmetricKey(size: .bits256)
    let state = ViewState(
        live: true, answers: [AnswerCard(id: "a", text: "A private answer", status: "complete")],
        selectedID: "a")
    let packet = try encryptedPacket(state, room: "room", sequence: 7, key: key)
    #expect(!packet.contains(state.answers[0].text))
    let json = try #require(JSONSerialization.jsonObject(with: Data(packet.utf8)) as? [String: Any])
    let encoded = try #require(json["box"] as? String)
    let box = try AES.GCM.SealedBox(combined: #require(Data(base64Encoded: encoded)))
    let plaintext = try AES.GCM.open(box, using: key, authenticating: Data("room:7".utf8))
    #expect(try JSONDecoder().decode(ViewState.self, from: plaintext) == state)
    #expect(throws: (any Error).self) {
        try AES.GCM.open(box, using: key, authenticating: Data("room:8".utf8))
    }
}

@Test func shortcutModifiersUseAppleOrderAndNeedTwoKnownKeys() {
    let all: ShortcutModifiers = [.command, .shift, .option, .control]
    #expect(all.symbols == "⌃⌥⇧⌘" && all.names == "Control + Option + Shift + Command")
    #expect(ShortcutModifiers.standard.symbols == ViewState().modifiers)
    #expect(ViewState().modifiers == "⌃⌥⌘")
    #expect(ShortcutKey.space.hint([.option, .command]) == "Option + Command + Space")
    #expect(!ShortcutModifiers().isValid && !ShortcutModifiers.shift.isValid)
    #expect(ShortcutModifiers([.shift, .command]).isValid && all.isValid)
    #expect(!ShortcutModifiers(rawValue: 1 << 4 | 1 << 0).isValid)
}

@Test func modifierRecordingCommitsAnActuallyHeldCombinationOnRelease() {
    var recording = ModifierRecording()
    #expect(recording.update(.control) == nil)
    #expect(recording.update([.control, .option]) == nil)
    #expect(recording.update(.control) == nil)
    #expect(recording.update([.control, .shift]) == nil)
    #expect(recording.update(.shift) == nil)
    #expect(recording.update([]) == [.control, .shift])
    #expect(recording.peak.isEmpty)
}

@Test func modifierRecordingDiscardsNavigationAndReleasesAfterFocusChanges() {
    var recording = ModifierRecording()
    _ = recording.update(.shift)
    recording.cancel()
    #expect(recording.update([]) == nil)
    recording = ModifierRecording(held: [.shift, .command])
    #expect(recording.update(.command) == nil)
    #expect(recording.update([]) == nil)
    _ = recording.update([.control, .option])
    recording.cancel()
    #expect(recording.update(.control) == nil)
    #expect(recording.update([]) == nil)
    _ = recording.update([.shift, .command])
    #expect(recording.update([]) == [.shift, .command])
}

@Test func base64URLWireVectors() {
    let vectors: [(Data, String)] = [
        (Data(), ""), (Data("f".utf8), "Zg"), (Data("fo".utf8), "Zm8"),
        (Data("foo".utf8), "Zm9v"), (Data("foob".utf8), "Zm9vYg"),
        (Data("fooba".utf8), "Zm9vYmE"), (Data("foobar".utf8), "Zm9vYmFy"),
        (Data([0xfb, 0xef, 0xff]), "--__"),
    ]
    for (bytes, encoded) in vectors {
        #expect(bytes.base64URLEncodedString() == encoded)
        #expect(Data(base64URLEncoded: encoded) == bytes)
    }
    #expect(Data(base64URLEncoded: "Zg==") == Data("f".utf8))
    #expect(Data(base64URLEncoded: "Zm8=") == Data("fo".utf8))
    for invalid in ["a", "%%%", "AA===", "-", "___?", "🐢"] {
        #expect(Data(base64URLEncoded: invalid) == nil)
    }
    // RFC 7636, Appendix B: the same SHA-256 and URL alphabet used for OAuth PKCE.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func historyInputAndViewerCommands() throws {
    var history = InterviewHistory()
    let first = Observation(
        requestID: "a", cutoff: 10,
        transcript: [
            TranscriptSegment(
                id: "mic.1", source: .microphone, start: 3, end: 4, text: "I have not used a map.")
        ], screenshot: Data([1]), screenshotTime: 10.1)
    history.append(first)
    history.update("a", answer: "Use a hash map.", completed: false)
    history.append(
        Observation(
            requestID: "b", cutoff: 20,
            transcript: [
                TranscriptSegment(
                    id: "computer.2", source: .computer, start: 19, end: 20,
                    text: "You cannot use a hash map.")
            ], screenshot: Data([2]), screenshotTime: 20.1))
    let messages = try history.input(through: "b")
    #expect(messages.count == 3)
    #expect((messages[1]["content"] as? String)?.contains("Incomplete suggestion") == true)
    let input = try JSONSerialization.data(withJSONObject: messages)
    let text = String(decoding: input, as: UTF8.self)
    #expect(text.components(separatedBy: "I have not used a map.").count == 2)
    #expect(text.contains("You cannot use a hash map."))
    #expect(text.contains("cutoff_seconds"))
    #expect(text.contains("input_image"))
    var state = ViewState(live: true)
    state.beginAnswer(id: "a")
    state.beginAnswer(id: "b")
    state.select(-1)
    #expect(state.selectedID == "a")
    state.select(-1)
    #expect(state.selectedID == "a")
    state.select(1)
    state.select(1)
    #expect(state.selectedID == "b")
    state.scroll(1)
    #expect(state.command == ViewerCommand(id: 1, answerID: "b", direction: 1))
    state.scroll(-1)
    #expect(state.command == ViewerCommand(id: 2, answerID: "b", direction: -1))
}

@Test func viewerSelectionUsesTheSameCursorAsMacControls() {
    let request = ViewerSelectionRequest(client: "reader", id: 1)
    var state = ViewState(live: true)
    state.beginAnswer(id: "a")
    state.beginAnswer(id: "b")
    state.beginAnswer(id: "c")
    let selected = state.select(answerID: "a", request: request)
    #expect(selected)
    #expect(state.selection == 4)
    #expect(state.selectionRequest == request)
    state.scroll(1)
    #expect(state.command?.answerID == "a")
    state.select(1)
    #expect(state.selectedID == "b")
    #expect(state.selectionRequest == nil)
    #expect(state.selection == 5)

    let selectedAgain = state.select(answerID: "b", request: request)
    #expect(selectedAgain)
    #expect(state.selection == 6)
    #expect(state.selectionRequest == request)
    let beforeInvalid = state
    let selectedMissing = state.select(answerID: "missing", request: request)
    #expect(!selectedMissing)
    #expect(state == beforeInvalid)
    state.beginAnswer(id: "d")
    #expect(state.selectionRequest == nil)
    #expect(state.selectedID == "d")
    state.live = false
    let ended = state
    let selectedAfterEnd = state.select(answerID: "a", request: request)
    #expect(!selectedAfterEnd)
    #expect(state == ended)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SKILL_ISSUE_ASR_CHECK_DIR"] != nil))
func twoSourcesAndAnswerCuts() async throws {
    let directory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SKILL_ISSUE_ASR_CHECK_DIR"]!)
    let english = try AudioFileLoader.load(
        url: directory.appendingPathComponent("en_constraints.wav"), targetSampleRate: 16000)
    let russian = try AudioFileLoader.load(
        url: directory.appendingPathComponent("ru_constraints.wav"), targetSampleRate: 16000)
    let engine = SpeechEngine()
    try await engine.prepare(progress: { _ in })
    try await engine.start(failed: {})
    for offset in stride(from: 0, to: max(english.count, russian.count), by: 5120) {
        if offset < english.count {
            engine.receive(
                Array(english[offset..<min(offset + 5120, english.count)]), source: .computer,
                seconds: Double(offset) / 16000)
        }
        if offset < russian.count {
            engine.receive(
                Array(russian[offset..<min(offset + 5120, russian.count)]), source: .microphone,
                seconds: Double(offset) / 16000)
        }
    }
    let batch = try await withCheckedThrowingContinuation { continuation in
        engine.freeze { continuation.resume(with: $0) }
        // This later buffer must enter the next batch even while the first
        // batch is still being finalized on the inference queue.
        engine.receive(english, source: .computer, seconds: 20)
    }
    let en = batch.filter { $0.source == .computer }.map(\.text).joined(separator: " ")
    let ru = batch.filter { $0.source == .microphone }.map(\.text).joined(separator: " ")
    #expect(en.contains("do not sort"))
    #expect(en.contains("not the values"))
    #expect(ru.contains("сортировать нельзя"))
    #expect(ru.contains("а не сами значения"))
    #expect(batch.allSatisfy { $0.start <= $0.end && $0.end <= 12 })
    let next = try await withCheckedThrowingContinuation { continuation in
        engine.freeze { continuation.resume(with: $0) }
    }
    #expect(!next.isEmpty)
    #expect(next.allSatisfy { $0.source == .computer && $0.start >= 20 })
    #expect(next.map(\.text).joined(separator: " ").contains("do not sort"))
    engine.receive([Float](repeating: 0, count: 16000), source: .computer, seconds: 32)
    let silence = try await withCheckedThrowingContinuation { continuation in
        engine.freeze { continuation.resume(with: $0) }
    }
    #expect(silence.isEmpty)
    await engine.stop()
    try await engine.start(failed: {})
    engine.receive(english, source: .computer, seconds: 0)
    let restart = try await withCheckedThrowingContinuation { continuation in
        engine.freeze { continuation.resume(with: $0) }
    }
    #expect(restart.allSatisfy { $0.source == .computer })
    #expect(restart.map(\.text).joined(separator: " ").contains("do not sort"))
    await engine.stop()
}
