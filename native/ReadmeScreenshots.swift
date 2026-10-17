#if README_SCREENSHOTS
    import AppKit
    import SwiftUI

    // Only the isolated README build includes this entry point and its fixtures.
    @MainActor
    enum ReadmeScreenshots {
        static func run() {
            let app = NSApplication.shared
            let delegate = ScreenshotDelegate()
            app.setActivationPolicy(.regular)
            app.appearance = NSAppearance(named: .darkAqua)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }

    @MainActor
    private final class ScreenshotDelegate: NSObject, NSApplicationDelegate {
        private var window: NSWindow?

        func applicationDidFinishLaunching(_ notification: Notification) {
            // Bound the lifetime even if AppKit or an async fixture stops responding.
            alarm(30)
            // Preserve enabled control styling without allowing a demo session to start.
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil
            }
            Task {
                let output = URL(fileURLWithPath: CommandLine.arguments[1])
                do {
                    try String(getpid()).write(
                        to: output.appendingPathExtension("pid"), atomically: true, encoding: .utf8)
                    try await capture(to: output)
                } catch {
                    try? String(describing: error).write(
                        to: output.appendingPathExtension("error"), atomically: true,
                        encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        }

        private func capture(to output: URL) async throws {
            let defaults = ScreenshotDefaults()
            defaults.set("https://skill-issue.example.workers.dev", forKey: "relayURL")
            defaults.set("gpt-6-luna", forKey: "chatGPTModel")
            defaults.set("low", forKey: "chatGPTReasoningEffort")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScreenshotHTTP.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let account = ChatGPTAccount(
                clientID: "demo", subject: "demo", email: "demo@example.com",
                session: ChatGPTSession(
                    idToken: "demo", accessToken: "demo", refreshToken: "demo",
                    expires: .distantFuture, scopes: ["chatgpt.tokens.use.direct"]))
            let model = Model(
                chatGPT: ChatGPT(
                    session: session,
                    storage: AccountStorage(
                        load: { ChatGPTAccounts(account: account) }, save: { _ in }),
                    defaults: defaults, openAuthorization: { _ in false }),
                defaults: defaults,
                viewerAccessStorage: ViewerAccessStorage(load: { _ in nil }, save: { _ in }))
            let deadline = ContinuousClock.now + .seconds(10)
            while model.working && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard model.status == "Ready", model.account == "demo@example.com",
                model.modelSlug == "gpt-6-luna", model.reasoningEffort == "low"
            else {
                throw ScreenshotFailure("Settings fixture did not become ready: \(model.status)")
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            self.window = window
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: SettingsView(model: model, toggleIcon: {}))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await Task.sleep(for: .seconds(1))
            let activationDeadline = ContinuousClock.now + .seconds(3)
            while !(window.isKeyWindow && NSApp.isActive),
                ContinuousClock.now < activationDeadline
            {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                try await Task.sleep(for: .milliseconds(100))
            }
            guard window.isKeyWindow, NSApp.isActive else {
                throw ScreenshotFailure(
                    "The screenshot window could not become active. Keep the desktop unlocked and avoid switching apps during capture, then retry."
                )
            }
            guard let view = window.contentView?.superview else {
                throw ScreenshotFailure("The screenshot window has no content view.")
            }
            window.makeFirstResponder(nil)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Export the view itself, including its title bar, without Screen Recording permission.
            let size = view.bounds.size
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                    pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)
            else { throw ScreenshotFailure("Could not create the Settings bitmap.") }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ScreenshotFailure("Could not encode the Settings PNG.")
            }
            try png.write(to: output, options: .atomic)
        }
    }

    private struct ScreenshotFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private final class ScreenshotHTTP: URLProtocol, @unchecked Sendable {
        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, url.path == "/v1/models" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let body = """
                {"models":[{"slug":"gpt-6-luna","display_name":"GPT-6-Luna","visibility":"list",
                "support_verbosity":true,
                "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]}]}
                """
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class ScreenshotDefaults: UserDefaults {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        init() { super.init(suiteName: "skill-issue-readme-screenshots")! }
        override func string(forKey defaultName: String) -> String? {
            lock.withLock { values[defaultName] as? String }
        }
        override func integer(forKey defaultName: String) -> Int {
            lock.withLock { values[defaultName] as? Int ?? 0 }
        }
        override func bool(forKey defaultName: String) -> Bool {
            lock.withLock { values[defaultName] as? Bool ?? false }
        }
        override func dictionary(forKey defaultName: String) -> [String: Any]? {
            lock.withLock { values[defaultName] as? [String: Any] }
        }
        override func set(_ value: Any?, forKey defaultName: String) {
            lock.withLock { values[defaultName] = value }
        }
        override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }
    }
#endif
