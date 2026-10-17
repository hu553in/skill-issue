import Foundation
import ScreenCaptureKit
import Testing

@testable import SkillIssue

struct CaptureInputsTests {
    @Test func defaultsPreserveTheExistingMicrophoneAndExplicitOffSurvivesRestart() {
        let defaults = TestDefaults()
        #expect(CaptureInputs(defaults: defaults) == CaptureInputs())
        defaults.set("external-microphone", forKey: "microphone")
        #expect(CaptureInputs(defaults: defaults).microphone == "external-microphone")
        CaptureInputs(microphone: nil, systemAudio: false).save(to: defaults)
        let restored = CaptureInputs(defaults: defaults)
        #expect(restored.microphone == nil && !restored.systemAudio && restored.screenshots)
        CaptureInputs().save(to: defaults)
        #expect(CaptureInputs(defaults: defaults) == CaptureInputs())
    }

    @Test func malformedPreferencesKeepValidChoicesAndRestoreDefaultsIndependently() {
        let defaults = TestDefaults()
        defaults.set(
            [
                "microphone": false, "systemAudio": "invalid", "screenshots": false,
                "display": "unknown-display",
            ],
            forKey: "captureInputs")
        let restored = CaptureInputs(defaults: defaults)
        #expect(restored.microphone == nil && restored.systemAudio && !restored.screenshots)
        #expect(restored.display == .main)

        defaults.set(
            ["microphone": true, "systemAudio": false, "screenshots": "invalid", "display": "all"],
            forKey: "captureInputs")
        let partiallyRestored = CaptureInputs(defaults: defaults)
        #expect(partiallyRestored.microphone?.isEmpty == true && !partiallyRestored.systemAudio)
        #expect(partiallyRestored.screenshots && partiallyRestored.display == .all)
    }

    @Test(arguments: [DisplaySelection.main, .all, .display(UUID())])
    func displaySelectionSurvivesRestartWithScreenshotsDisabled(_ selection: DisplaySelection) {
        let defaults = TestDefaults()
        let inputs = CaptureInputs(screenshots: false, display: selection)
        inputs.save(to: defaults)
        let restored = CaptureInputs(defaults: defaults)
        #expect(restored == inputs)
        #expect(restored.isEnabled && restored.hasAudio)
    }

    @Test(arguments: 0..<8)
    func sourceCombinationsConfigureOnlyTheSelectedAudio(_ mask: Int) {
        let microphone = mask & 1 != 0
        let systemAudio = mask & 2 != 0
        let screenshots = mask & 4 != 0
        let inputs = CaptureInputs(
            microphone: microphone ? "selected-device" : nil,
            systemAudio: systemAudio, screenshots: screenshots)
        #expect(inputs.isEnabled == (mask != 0))
        #expect(inputs.hasAudio == (mask != 0 && mask != 4))
        let configuration = inputs.streamConfiguration()
        #expect(configuration.captureMicrophone == microphone)
        #expect(configuration.capturesAudio == systemAudio)
        #expect(configuration.microphoneCaptureDeviceID == (microphone ? "selected-device" : nil))
        let defaults = TestDefaults()
        inputs.save(to: defaults)
        #expect(CaptureInputs(defaults: defaults) == inputs)
    }

    @Test func audioOnlyRequestsRetainTheirTranscriptWithoutAnImage() throws {
        let observation = Observation(
            requestID: "audio", cutoff: 5,
            transcript: [
                TranscriptSegment(
                    id: "mic", source: .microphone, start: 1, end: 3,
                    text: "Explain optimistic locking.")
            ])
        let content = try #require(observation.input()["content"] as? [[String: String]])
        #expect(content.count == 1 && content[0]["type"] == "input_text")
        let text = try #require(content[0]["text"])
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let screenshots = try #require(json["screenshots"] as? [[String: Any]])
        #expect(screenshots.isEmpty)
        let transcript = try #require(json["transcript"] as? [[String: Any]])
        #expect(
            transcript.count == 1
                && transcript[0]["text"] as? String == "Explain optimistic locking.")
    }
}
