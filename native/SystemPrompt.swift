import AppKit
import SwiftUI

enum SystemPrompt {
    static func load() throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: "prompt", withExtension: "md", subdirectory: "Resources")
        else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
final class SystemPromptWindow: NSWindowController {
    init(prompt: String) {
        let window = ApplicationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "System prompt"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: SystemPromptView(prompt: prompt, close: { [weak self] in self?.close() }))
        if let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame {
            let available = window.contentRect(forFrameRect: visible).size
            window.contentMinSize = NSSize(
                width: min(360, available.width), height: min(240, available.height))
            window.setContentSize(
                NSSize(width: min(640, available.width), height: min(560, available.height)))
            window.setFrameOrigin(
                NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SystemPromptView: View {
    let prompt: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("System prompt").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            SystemPromptText(prompt: prompt)
                .padding(SettingsLayout.textInset)
                .settingsFieldBackground()
            HStack {
                Spacer(minLength: 0)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(SettingsLayout.windowPadding)
    }
}

struct SystemPromptText: NSViewRepresentable {
    let prompt: String

    func makeNSView(context: Context) -> NSScrollView { makeScrollView() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
            textView.string != prompt
        else { return }
        textView.string = prompt
    }

    func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.string = prompt
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setAccessibilityLabel("System prompt")
        scrollView.documentView = textView
        return scrollView
    }
}
