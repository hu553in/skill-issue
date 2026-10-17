import AppKit
import Carbon
import SwiftUI

struct ShortcutModifiersConfiguration: View {
    let save: (ShortcutModifiers) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers: ShortcutModifiers
    @State private var error = ""
    private var message: String {
        if !error.isEmpty { return error }
        return modifiers.isEmpty || modifiers.isValid ? "" : "Use at least two modifier keys."
    }

    init(modifiers: ShortcutModifiers, save: @escaping (ShortcutModifiers) throws -> Void) {
        self.save = save
        _modifiers = State(initialValue: modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            Text("Shortcut modifiers").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Press and release at least two modifier keys.").font(.subheadline)
                .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                SettingsNotice(
                    messages: [message], warning: false, diagnostic: "", actionTitle: nil,
                    actionDisabled: false, action: {}, retryModels: nil,
                    retryModelsDisabled: true, detailsExpanded: .constant(false))
            }
            LabeledContent("Modifier keys") {
                ModifierRecorder(modifiers: $modifiers)
            }.accessibilityElement(children: .contain)
            HStack(spacing: SettingsLayout.spacing) {
                Button("Restore default") { modifiers = .standard }
                    .disabled(modifiers == .standard)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: saveModifiers).keyboardShortcut(.defaultAction)
                    .disabled(!modifiers.isValid)
                    .help(modifiers.isValid ? "" : "Press at least two modifier keys first.")
            }
        }
        .padding(SettingsLayout.windowPadding).frame(width: SettingsLayout.sheetWidth)
        .onChange(of: modifiers) { error = "" }
        .onChange(of: message) { _, message in
            guard !message.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    private func saveModifiers() {
        do {
            try save(modifiers)
            dismiss()
        } catch {
            self.error = (error as? AppFailure)?.message ?? failureMessage
        }
    }
}

// Ignore navigation and app-switching chords until all their modifiers are released.
struct ModifierRecording {
    private(set) var peak: ShortcutModifiers = []
    private var cancelled = false
    private var held: ShortcutModifiers

    init(held: ShortcutModifiers = []) { self.held = held }

    mutating func update(_ current: ShortcutModifiers) -> ShortcutModifiers? {
        let pressed = !current.subtracting(held).isEmpty
        held = current
        if current.isEmpty {
            let result = cancelled || peak.isEmpty ? nil : peak
            self = Self()
            return result
        }
        guard !cancelled, pressed else { return nil }
        if current.rawValue.nonzeroBitCount >= peak.rawValue.nonzeroBitCount { peak = current }
        return nil
    }

    mutating func cancel() {
        peak = []
        cancelled = true
    }
}

private struct ModifierRecorder: View {
    @Binding var modifiers: ShortcutModifiers
    @State private var recording = ModifierRecording()
    @State private var monitor: Any?
    @FocusState private var focused: Bool
    // The set stays visible while keys are released one by one.
    private var shown: ShortcutModifiers { recording.peak.isEmpty ? modifiers : recording.peak }

    var body: some View {
        HStack(spacing: SettingsLayout.compactSpacing) {
            if shown.isEmpty {
                Text("Press modifier keys")
                    .foregroundStyle(Color(nsColor: SettingsColors.secondaryText))
            } else {
                ShortcutModifierSymbols(modifiers: shown)
            }
            Spacer(minLength: 0)
            if !modifiers.isEmpty && recording.peak.isEmpty {
                Button {
                    modifiers = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear modifier keys")
            }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .settingsFieldBackground()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .focusable(interactions: .edit).focused($focused)
        .onAppear { focused = true }
        .onChange(of: focused, initial: true) { _, focused in
            if focused { startRecording() } else { stopRecording() }
        }
        .onDisappear(perform: stopRecording)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
        ) {
            _ in recording.cancel()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) {
            _ in recording = ModifierRecording(held: ShortcutModifiers(NSEvent.modifierFlags))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Modifier keys")
        .accessibilityValue(shown.isEmpty ? "None" : shown.names)
        .accessibilityHint("Hold the modifier keys, then release them.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { focused = true }
        .accessibilityAction(named: "Clear") { modifiers = [] }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        recording = ModifierRecording(held: ShortcutModifiers(NSEvent.modifierFlags))
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown], handler: record)
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = ModifierRecording()
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        let current = ShortcutModifiers(event.modifierFlags)
        if event.type == .flagsChanged {
            if let selected = recording.update(current) {
                modifiers = selected
            }
            return event
        }
        recording.cancel()
        if current.isEmpty { recording = ModifierRecording() }
        if Int(event.keyCode) == kVK_Tab { return event }
        // Keys pressed with modifiers, including menu shortcuts such as ⌘Q, are not recorded.
        if !current.isEmpty { return nil }
        if [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            modifiers = []
            return nil
        }
        return event
    }
}

extension ShortcutModifiers {
    fileprivate init(_ flags: NSEvent.ModifierFlags) {
        self = []
        for (modifier, flag) in [
            (Self.control, NSEvent.ModifierFlags.control), (.option, .option), (.shift, .shift),
            (.command, .command),
        ] where flags.contains(flag) {
            insert(modifier)
        }
    }
}
