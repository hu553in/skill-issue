import AppKit

final class ApplicationWindow: NSWindow {
    var focusChanged: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { focusChanged?() }
        return accepted
    }
}
