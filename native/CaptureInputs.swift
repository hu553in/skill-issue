import Foundation

struct CaptureInputs: Equatable, Sendable {
    // nil disables the microphone; an empty identifier selects the system default.
    var microphone: String? = ""
    var systemAudio = true
    var screenshots = true
    var display: DisplaySelection = .main

    var hasAudio: Bool { microphone != nil || systemAudio }
    var isEnabled: Bool { hasAudio || screenshots }
    var unavailableReason: String? { isEnabled ? nil : "Enable at least one input." }
}

extension CaptureInputs {
    init(defaults: UserDefaults) {
        let fields = defaults.dictionary(forKey: "captureInputs") ?? [:]
        microphone =
            fields["microphone"] as? Bool == false
            ? nil : defaults.string(forKey: "microphone") ?? ""
        systemAudio = fields["systemAudio"] as? Bool ?? true
        screenshots = fields["screenshots"] as? Bool ?? true
        display = (fields["display"] as? String).flatMap(DisplaySelection.init(rawValue:)) ?? .main
    }

    func save(to defaults: UserDefaults) {
        defaults.set(microphone, forKey: "microphone")
        defaults.set(
            [
                "microphone": microphone != nil, "systemAudio": systemAudio,
                "screenshots": screenshots,
                "display": display.rawValue,
            ], forKey: "captureInputs")
    }
}
