import AppKit
import Foundation
import Testing

@testable import SkillIssue

struct SystemPromptTests {
    @Test func bundledPromptMatchesSourceExactly() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "native/Resources/prompt.md")
        #expect(try Data(SystemPrompt.load().utf8) == Data(contentsOf: source))
    }

    @MainActor @Test func promptCanBeSelectedWithoutBeingEdited() throws {
        let prompt = "# System prompt\n\nPreserve unicode 🐢 and trailing whitespace.  \n"
        let scrollView = SystemPromptText(prompt: prompt).makeScrollView()
        let textView = try #require(scrollView.documentView as? NSTextView)
        #expect(textView.string == prompt)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: prompt.utf16.count))
        textView.insertText("replacement", replacementRange: textView.selectedRange())
        #expect(textView.string == prompt)
    }
}
