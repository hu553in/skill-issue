import CryptoKit
import Foundation
import SimpleKeychain

enum AppFailure: Error {
    case failed, microphonePermission, screenCapturePermission
    case shortcutUnavailable(String)

    var message: String {
        switch self {
        case .failed: return failureMessage
        case .microphonePermission:
            return
                "Allow Skill Issue in System Settings > Privacy & Security > Microphone, then start the session again."
        case .screenCapturePermission:
            return
                "Allow Skill Issue in System Settings > Privacy & Security > Screen & System Audio Recording. Quit and reopen the app if macOS asks, then start the session again."
        case .shortcutUnavailable(let shortcut):
            return "\(shortcut) is already used by another app. Choose other modifier keys."
        }
    }
}
let failureMessage = "Couldn't complete that. Try again."
let fontSizeRange = 16...40
let maximumPacket = 4_000_000

// Preserve the existing macOS Keychain backend so saved records remain readable.
let credentialKeychain = SimpleKeychain(
    service: "com.github.hu553in.skill-issue", accessibility: .afterFirstUnlockThisDeviceOnly)

extension Data {
    static func random() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

struct ShortcutModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let standard: Self = [.control, .option, .command]
    // Apple's display order. Carbon hot keys support no other modifiers.
    static let ordered: [(modifier: Self, symbol: String, name: String, image: String)] = [
        (.control, "⌃", "Control", "control"), (.option, "⌥", "Option", "option"),
        (.shift, "⇧", "Shift", "shift"), (.command, "⌘", "Command", "command"),
    ]

    var symbols: String { Self.ordered.filter { contains($0.modifier) }.map(\.symbol).joined() }
    var names: String {
        Self.ordered.filter { contains($0.modifier) }.map(\.name).joined(separator: " + ")
    }
    // A single global modifier would take over typing and system shortcuts such as ⌘Space.
    var isValid: Bool {
        isSubset(of: [.control, .option, .shift, .command]) && rawValue.nonzeroBitCount >= 2
    }
}

enum AudioSource: String, Codable, Sendable { case computer, microphone }
struct TranscriptSegment: Codable, Equatable, Sendable {
    var id: String
    var source: AudioSource
    var start: Double
    var end: Double
    var text: String
}
struct AnswerCard: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text = ""
    var status = "generating"
}
struct ViewerCommand: Codable, Equatable, Sendable {
    var id: Int
    var answerID: String?
    var direction: Int
}
struct ViewState: Codable, Equatable, Sendable {
    // Codable sends this protocol version to the web viewer.
    // swiftlint:disable:next unused_declaration
    var version = 1
    var live = false
    var canAnswer = false
    var answers: [AnswerCard] = []
    var selectedID: String?
    var selection = 0
    var command: ViewerCommand?
    var fontSize = 20
    var language = "English"
    // Codable sends the shortcut reminder to the web viewer.
    var modifiers = ShortcutModifiers.standard.symbols
    var error = ""

    mutating func select(_ offset: Int) {
        guard !answers.isEmpty else { return }
        let current = answers.firstIndex { $0.id == selectedID } ?? answers.count - 1
        let next = min(answers.count - 1, max(0, current + offset))
        guard next != current else { return }
        selectedID = answers[next].id
        selection += 1
    }
    mutating func beginAnswer(id: String) {
        answers.append(AnswerCard(id: id))
        selectedID = id
        selection += 1
    }
    mutating func scroll(_ direction: Int) {
        command = ViewerCommand(
            id: (command?.id ?? 0) + 1, answerID: selectedID, direction: direction)
    }
}

struct Observation: Sendable {
    var requestID: String
    var cutoff: Double
    var transcript: [TranscriptSegment]
    var screenshot: Data?
    var screenshotTime: Double?

    func input() throws -> [String: Any] {
        var value: [String: Any] = [
            "request_id": requestID, "cutoff_seconds": cutoff,
            "transcript": transcript.map {
                [
                    "id": $0.id, "source": $0.source.rawValue, "start_seconds": $0.start,
                    "end_seconds": $0.end, "text": $0.text,
                ] as [String: Any]
            },
        ]
        if let screenshotTime {
            value["screenshot"] = [
                "captured_at_seconds": screenshotTime,
                "description": "Main Mac display at this request",
            ]
        }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        var content: [[String: Any]] = [
            ["type": "input_text", "text": String(decoding: bytes, as: UTF8.self)]
        ]
        if let screenshot {
            content.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(screenshot.base64EncodedString())",
            ])
        }
        return ["role": "user", "content": content]
    }
}
struct InterviewHistory {
    struct Turn {
        var observation: Observation
        var answer = ""
        var completed = false
    }
    private(set) var turns: [Turn] = []
    mutating func append(_ observation: Observation) {
        turns.append(Turn(observation: observation))
    }
    mutating func update(_ id: String, answer: String, completed: Bool) {
        guard let index = turns.firstIndex(where: { $0.observation.requestID == id }) else {
            return
        }
        turns[index].answer = answer
        turns[index].completed = completed
    }
    func input(through id: String) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for turn in turns {
            messages.append(try turn.observation.input())
            if turn.observation.requestID == id { break }
            if !turn.answer.isEmpty {
                messages.append([
                    "role": "assistant",
                    "content": turn.completed
                        ? turn.answer
                        : "[Incomplete suggestion: generation was cancelled or failed.]\n\(turn.answer)"
                        ,
                ])
            }
        }
        return messages
    }
}

func encryptedPacket(_ state: ViewState, room: String, sequence: Int, key: SymmetricKey) throws
    -> String
{
    let box = try AES.GCM.seal(
        JSONEncoder().encode(state), using: key, authenticating: Data("\(room):\(sequence)".utf8))
    guard let combined = box.combined else { throw AppFailure.failed }
    let data = try JSONSerialization.data(withJSONObject: [
        "type": "state", "seq": sequence, "box": combined.base64EncodedString(),
    ])
    guard data.count <= maximumPacket else { throw AppFailure.failed }
    return String(decoding: data, as: UTF8.self)
}
