import Foundation
import Testing

@testable import SkillIssue

@MainActor
@Test func failedSessionStopsControlsAndKeepsPartialAnswer() async throws {
    let chatGPT = ChatGPT(storage: CredentialStorage(load: { nil }, save: { _ in }, delete: {}))
    let model = Model(chatGPT: chatGPT)
    let deadline = ContinuousClock.now + .seconds(3)
    while model.working, ContinuousClock.now < deadline { await Task.yield() }
    try #require(!model.working)

    model.account = "fake@example.invalid"
    model.mode = "answer"
    model.state.live = true
    model.answer()
    model.state.answers[0].text = "A partial suggestion"
    model.link = URL(string: "https://example.invalid")
    let ending = model.endSession(failed: true)
    #expect(!model.canAnswer)
    #expect(model.link == nil)
    let command = model.state.command
    model.scroll(1)
    model.navigate(-1)
    model.answer()
    #expect(model.state.command == command)
    await ending.value
    #expect(!model.state.live && !model.working)
    #expect(model.status == "Ready")
    #expect(model.state.error == failureMessage)
    #expect(model.state.answers.count == 1)
    #expect(model.state.answers[0].text == "A partial suggestion")
    #expect(model.state.answers[0].status == "incomplete")
    // Repeated cleanup and a later cancelled callback must not re-enable controls.
    await model.shutdown()
    #expect(!model.canAnswer)
    #expect(model.state.answers[0].status == "incomplete")
}
