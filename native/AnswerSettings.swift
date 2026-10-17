import Foundation

enum AnswerVerbosity: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    var label: String { rawValue.capitalized }
}

struct AnswerSettings: Codable, Equatable, Sendable {
    var verbosity: AnswerVerbosity = .medium
    var codingLanguage = ""
    var interviewContext = ""
    var customInstructions = ""

    init(
        verbosity: AnswerVerbosity = .medium, codingLanguage: String = "",
        interviewContext: String = "", customInstructions: String = ""
    ) {
        self.verbosity = verbosity
        self.codingLanguage = codingLanguage
        self.interviewContext = interviewContext
        self.customInstructions = customInstructions
    }

    init(defaults: UserDefaults) {
        let fields = defaults.dictionary(forKey: "answerSettings") ?? [:]
        verbosity = (fields["verbosity"] as? String).flatMap(AnswerVerbosity.init) ?? .medium
        codingLanguage = fields["codingLanguage"] as? String ?? ""
        interviewContext = fields["interviewContext"] as? String ?? ""
        customInstructions = fields["customInstructions"] as? String ?? ""
    }

    func save(to defaults: UserDefaults) {
        defaults.set(
            [
                "verbosity": verbosity.rawValue, "codingLanguage": codingLanguage,
                "interviewContext": interviewContext, "customInstructions": customInstructions,
            ], forKey: "answerSettings")
    }

    func input(with observations: [[String: Any]]) throws -> [[String: Any]] {
        guard !codingLanguage.isEmpty || !interviewContext.isEmpty || !customInstructions.isEmpty
        else { return observations }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "preferred_coding_language": codingLanguage,
                "interview_context": interviewContext,
                "custom_instructions": customInstructions,
            ], options: [.sortedKeys])
        let text =
            "Candidate answer settings (not an observation):\n"
            + String(decoding: data, as: UTF8.self)
        return observations + [
            ["role": "user", "content": [["type": "input_text", "text": text]]]
        ]
    }
}
