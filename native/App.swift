import AVFoundation
import AppKit
import Carbon
import CoreImage.CIFilterBuiltins
import SwiftUI

private struct AnswerLanguage: Decodable, Sendable {
    let name: String
    let label: String
    // The language list is a required bundled application resource.
    // swiftlint:disable:next force_try
    static let all = try! JSONDecoder().decode(
        [Self].self,
        from: Data(
            contentsOf:
                Bundle.module.url(
                    forResource: "answer-languages", withExtension: "json",
                    subdirectory: "Resources")!))
}

@MainActor
final class Model: ObservableObject {
    @Published var relayURL =
        UserDefaults.standard.string(forKey: "relayURL") ?? "http://127.0.0.1:8787"
    @Published var microphone = UserDefaults.standard.string(forKey: "microphone") ?? ""
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "English"
    @Published var mode = UserDefaults.standard.string(forKey: "mode") ?? "answer"
    @Published var account = ""
    @Published var link: URL?
    @Published var working = false
    @Published var status = "Ready"
    @Published var viewerStatus = "Open the viewer on your phone."
    @Published var iconVisible = true
    @Published var error = ""
    @Published var state = ViewState()
    private let chatGPT: ChatGPT
    private let capture = Capture()
    private var relay: Relay?
    private var history = InterviewHistory()
    private var sessionID = UUID()
    private var currentRequest: String?
    private var answerTask: Task<Void, Never>?
    private var snapshotTask: Task<Observation, Error>?
    private var publishTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var terminating = false
    private var captureFailure: UUID?
    var canAnswer: Bool { state.live && !working && !account.isEmpty && mode == "answer" }

    init(chatGPT: ChatGPT = ChatGPT()) {
        self.chatGPT = chatGPT
        let savedFontSize = UserDefaults.standard.integer(forKey: "fontSize")
        if (16...40).contains(savedFontSize) { state.fontSize = savedFontSize }
        working = true
        status = "Loading…"
        Task {
            do {
                try await chatGPT.restore()
                account = chatGPT.credentials?.email ?? ""
            } catch { showError() }
            working = false
            status = "Ready"
        }
    }
    func authenticate() {
        guard !working, !state.live else { return }
        working = true
        error = ""
        Task {
            do {
                if account.isEmpty {
                    try await chatGPT.signIn()
                } else {
                    try await chatGPT.signOut()
                }
                account = chatGPT.credentials?.email ?? ""
            } catch {
                account = chatGPT.credentials?.email ?? ""
                showError()
            }
            working = false
        }
    }
    func startSession() {
        guard !terminating, !working, !state.live, !account.isEmpty else { return }
        publishTask?.cancel()
        monitorTask?.cancel()
        cancelAnswer()
        working = true
        error = ""
        status = "Preparing…"
        sessionID = UUID()
        let session = sessionID
        history = InterviewHistory()
        currentRequest = nil
        snapshotTask = nil
        captureFailure = nil
        state = ViewState(mode: mode, fontSize: state.fontSize, language: language)
        for (key, value) in [
            "relayURL": relayURL, "microphone": microphone, "language": language, "mode": mode,
        ] { UserDefaults.standard.set(value, forKey: key) }
        startTask = Task { [self] in
            defer { startTask = nil }
            do {
                try await capture.prepare { [weak self] message in
                    Task { @MainActor in if self?.sessionID == session { self?.status = message } }
                }
                try Task.checkCancellation()
                status = "Connecting ChatGPT…"
                try await chatGPT.prepareSession()
                try Task.checkCancellation()
                status = "Connecting viewer…"
                let relay = try await Relay.create(
                    url: relayURL.trimmingCharacters(in: .whitespacesAndNewlines))
                self.relay = relay
                link = relay.viewerURL
                try Task.checkCancellation()
                relay.onConnection = { [weak self] connected, count in
                    guard let self, self.sessionID == session else { return }
                    self.viewerStatus =
                        !connected
                        ? "Reconnecting viewer…"
                        : count == 0
                            ? "Open the viewer on your phone." : "Viewer ready · \(count) connected"
                }
                status = "Starting capture…"
                var text: (@Sendable ([TranscriptSegment]) -> Void)?
                if mode == "transcript" {
                    text = { @Sendable [weak self] transcript in
                        Task { @MainActor in
                            guard let self, self.sessionID == session else { return }
                            self.state.transcript = transcript
                        }
                    }
                }
                try await capture.start(
                    microphone: microphone, text: text,
                    failed: { [weak self] in self?.captureFailed(session: session) })
                try Task.checkCancellation()
                guard captureFailure != session else { throw AppFailure.failed }
                state.live = true
                status = "Listening"
                working = false
                try relay.publish(state)
                publishTask = Task { [weak self] in
                    var previous = self?.state
                    var heartbeat = Date()
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(150))
                            guard let self, self.sessionID == session else { return }
                            if self.state != previous || Date().timeIntervalSince(heartbeat) >= 15 {
                                try relay.publish(self.state)
                                previous = self.state
                                heartbeat = Date()
                            }
                        } catch {
                            if !Task.isCancelled, let self, self.sessionID == session {
                                self.endSession(failed: true)
                            }
                            return
                        }
                    }
                }
                monitorTask = Task { await relay.monitor() }
            } catch {
                await endSession(failed: !Task.isCancelled).value
            }
        }
    }
    func stopSession() {
        guard !working, state.live || relay != nil else { return }
        endSession()
    }
    @discardableResult
    func endSession(failed: Bool = false) -> Task<Void, Never> {
        if failed { showError() }
        if let endingTask { return endingTask }
        working = true
        status = "Stopping…"
        state.live = false
        cancelAnswer()
        sessionID = UUID()
        snapshotTask?.cancel()
        snapshotTask = nil
        publishTask?.cancel()
        publishTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        let old = relay
        relay = nil
        link = nil
        let task = Task {
            async let stopped: Void = capture.stop()
            do { try await old?.close() } catch { showError() }
            await stopped
            status = "Ready"
            working = false
            endingTask = nil
        }
        endingTask = task
        return task
    }
    func answer() {
        guard canAnswer else { return }
        cancelAnswer()
        let id = UUID().uuidString
        let session = sessionID
        currentRequest = id
        state.beginAnswer(id: id)
        state.error = ""
        error = ""
        let previous = snapshotTask
        // Both operations start at this key press. A newer request does not
        // cancel capture finalization or discard the older observation batch.
        let frozen = capture.freeze()
        let captured = Task { () throws -> Observation in
            async let image = try? capture.screenshot()
            for try await (cutoff, transcript) in frozen {
                let screenshot = await image
                return Observation(
                    requestID: id, cutoff: cutoff, transcript: transcript,
                    screenshot: screenshot?.0, screenshotTime: screenshot?.1)
            }
            throw AppFailure.failed
        }
        let snapshot = Task { () throws -> Observation in
            let observation = try await captured.value
            _ = try? await previous?.value
            guard sessionID == session else { throw CancellationError() }
            history.append(observation)
            return observation
        }
        snapshotTask = snapshot
        answerTask = Task {
            do {
                let observation = try await snapshot.value
                try Task.checkCancellation()
                guard observation.screenshot != nil, sessionID == session, currentRequest == id
                else { throw AppFailure.failed }
                let input = try history.input(through: id)
                try await chatGPT.answer(input: input, language: language) { [weak self] delta in
                    guard let self, self.sessionID == session, self.currentRequest == id,
                        let index = self.state.answers.firstIndex(where: { $0.id == id })
                    else { return }
                    self.state.answers[index].text += delta
                    self.history.update(
                        id, answer: self.state.answers[index].text, completed: false)
                }
                guard sessionID == session, currentRequest == id,
                    let index = state.answers.firstIndex(where: { $0.id == id })
                else { return }
                state.answers[index].status = "complete"
                history.update(id, answer: state.answers[index].text, completed: true)
            } catch {
                if !Task.isCancelled && sessionID == session && currentRequest == id {
                    if let index = state.answers.firstIndex(where: { $0.id == id }) {
                        state.answers[index].status = "failed"
                    }
                    showError()
                }
            }
        }
        publish()
    }
    private func cancelAnswer() {
        answerTask?.cancel()
        answerTask = nil
        if let id = currentRequest, let index = state.answers.firstIndex(where: { $0.id == id }),
            state.answers[index].status == "generating"
        {
            state.answers[index].status = "incomplete"
            history.update(id, answer: state.answers[index].text, completed: false)
        }
        currentRequest = nil
    }
    func navigate(_ direction: Int) {
        guard state.live, mode == "answer" else { return }
        state.select(direction)
        publish()
    }
    func scroll(_ direction: Int) {
        guard state.live else { return }
        state.scroll(direction)
        publish()
    }
    func zoom(_ direction: Int) {
        guard state.live else { return }
        let size = min(40, max(16, state.fontSize + direction * 2))
        guard size != state.fontSize else { return }
        state.fontSize = size
        UserDefaults.standard.set(size, forKey: "fontSize")
        publish()
    }
    private func publish() { do { try relay?.publish(state) } catch { endSession(failed: true) } }
    private func showError() {
        error = failureMessage
        state.error = failureMessage
    }
    private func captureFailed(session: UUID) {
        guard sessionID == session else { return }
        captureFailure = session
        if state.live { endSession(failed: true) }
    }
    func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
    func openViewer() { if let link { NSWorkspace.shared.open(link) } }
    func shutdown() async {
        terminating = true
        startTask?.cancel()
        await startTask?.value
        await endSession().value
        await chatGPT.finishPendingRefresh()
    }
}

private struct SettingsView: View {
    @ObservedObject var model: Model
    let toggleIcon: () -> Void
    private var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
    private var answerIndex: Int {
        model.state.answers.firstIndex { $0.id == model.state.selectedID } ?? -1
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Skill Issue").font(.title2.weight(.semibold))
                Text(model.status).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ChatGPT").font(.headline)
                if !model.account.isEmpty {
                    Text(model.account).font(.subheadline).foregroundStyle(.secondary)
                }
                Button(
                    model.account.isEmpty ? "Continue with ChatGPT" : "Sign out",
                    action: model.authenticate
                ).disabled(model.working || model.state.live)
            }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Microphone", selection: $model.microphone) {
                    Text("System default").tag("")
                    ForEach(microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Picker("Answer language", selection: $model.language) {
                    ForEach(AnswerLanguage.all, id: \.name) { Text($0.label).tag($0.name) }
                }
                Picker("Viewer", selection: $model.mode) {
                    Text("Answers").tag("answer")
                    Text("Transcript preview").tag("transcript")
                }
                LabeledContent("Viewer server") {
                    TextField("https://…", text: $model.relayURL).textFieldStyle(.roundedBorder)
                }
                Text(
                    "Main display, computer audio and microphone. Speech is recognized locally in English, Russian and other supported languages. The model downloads once, before your first session."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }.disabled(model.working || model.state.live)
            if let link = model.link {
                HStack(spacing: 18) {
                    if let qr = qrCode(link.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(
                            width: 104, height: 104
                        ).padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.viewerStatus).font(.headline)
                        Text("Keep this private session link to yourself.").font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open viewer", action: model.openViewer)
                            Button("Copy link", action: model.copyLink)
                        }
                    }
                }
            }
            HStack {
                Button("Previous answer") { model.navigate(-1) }.disabled(
                    !model.canAnswer || answerIndex <= 0)
                Button("Next answer") { model.navigate(1) }.disabled(
                    !model.canAnswer || answerIndex >= model.state.answers.count - 1)
                Spacer()
                Button("Read up") { model.scroll(-1) }.disabled(!model.state.live)
                Button("Read down") { model.scroll(1) }.disabled(!model.state.live)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Hold \(shortcutModifiers) on your Mac").font(.subheadline.weight(.medium))
                Text("Space: answer · ↑↓: read · ←→: history · +/−: text size · H: hide/show icon")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
            }
            if !model.error.isEmpty { Text(model.error).font(.callout) }
            HStack {
                Button(model.iconVisible ? "Hide icon" : "Show icon", action: toggleIcon)
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                Spacer()
                Button("Answer", action: model.answer).disabled(!model.canAnswer)
                Button(model.state.live ? "Stop session" : "Start session") {
                    if model.state.live { model.stopSession() } else { model.startSession() }
                }
                .buttonStyle(.borderedProminent).disabled(model.working || model.account.isEmpty)
            }
        }.padding(26).frame(width: 520).fixedSize(horizontal: true, vertical: true)
    }
    private func qrCode(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage,
            let cg = CIContext().createCGImage(
                image.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                from: image.extent.applying(CGAffineTransform(scaleX: 6, y: 6)))
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var shortcuts: [EventHotKeyRef] = []
    private var held: Set<UInt32> = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        model.iconVisible = item.isVisible
        item.button?.image = NSImage(
            systemSymbolName: "arrow.up.forward.square",
            accessibilityDescription: "Skill Issue")
        item.button?.target = self
        item.button?.action = #selector(toggleSettings)
        let keys = [
            kVK_Space, kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_ANSI_H,
            kVK_ANSI_Equal, kVK_ANSI_Minus,
        ]
        for (index, key) in keys.enumerated() {
            // The + key also works without Shift, like the other commands.
            for extra in key == kVK_ANSI_Equal ? [0, shiftKey] : [0] {
                var reference: EventHotKeyRef?
                let result = RegisterEventHotKey(
                    UInt32(key), UInt32(controlKey | optionKey | cmdKey | extra),
                    EventHotKeyID(signature: 0x534B_494C, id: UInt32(index + 1)),
                    GetApplicationEventTarget(), 0, &reference)
                if result == noErr, let reference {
                    shortcuts.append(reference)
                } else {
                    model.error = failureMessage
                }
            }
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        var events = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                        nil, &id) == noErr, id.signature == 0x534B_494C
                else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                Task { @MainActor in delegate.hotkey(id.id, released: released) }
                return noErr
            }, 2, &events, opaque, nil)
        if installed != noErr { model.error = failureMessage }
        showSettings()
    }
    private func hotkey(_ id: UInt32, released: Bool) {
        if released {
            held.remove(id)
            return
        }
        if held.contains(id) && (id == 1 || id == 6) { return }
        held.insert(id)
        switch id {
        case 1: model.answer()
        case 2: model.scroll(-1)
        case 3: model.scroll(1)
        case 4: model.navigate(-1)
        case 5: model.navigate(1)
        case 6: toggleIcon()
        case 7: model.zoom(1)
        case 8: model.zoom(-1)
        default: break
        }
    }
    private func toggleIcon() {
        model.iconVisible.toggle()
        item.isVisible = model.iconVisible
    }
    @objc private func toggleSettings() {
        if let window, NSApp.isActive && window.isKeyWindow {
            window.close()
        } else {
            showSettings()
        }
    }
    private func showSettings() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    model: model, toggleIcon: { [weak self] in self?.toggleIcon() }))
            window.center()
            self.window = window
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        showSettings()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main enum SkillIssue {
    // Application entry point called through @main.
    // swiftlint:disable:next unused_declaration
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
