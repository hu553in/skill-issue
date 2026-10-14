import Carbon

let hotKeySignature: OSType = 0x534B_494C
// Hot key IDs are 1-based positions in this list.
let globalShortcutKeys: [ShortcutKey] = [
    .space, .up, .down, .left, .right, .menuBarIcon, .plus, .minus,
]

struct ShortcutRegistry: Sendable {
    // Replaces every global command together, retaining the current set on failure.
    var register: @MainActor @Sendable (ShortcutModifiers) throws -> Void
    var unregister: @MainActor @Sendable () -> Void

    static let disabled = Self(register: { _ in }, unregister: {})

    @MainActor static func carbon() -> Self {
        let hotKeys = CarbonHotKeys()
        return Self(register: hotKeys.register, unregister: hotKeys.unregister)
    }
}

@MainActor
final class CarbonHotKeys {
    typealias Register = (
        UInt32, UInt32, EventHotKeyID, EventTargetRef?, OptionBits,
        UnsafeMutablePointer<EventHotKeyRef?>?
    ) -> OSStatus
    private struct Combination: Hashable {
        let key: UInt32
        let flags: UInt32
    }
    private let registerHotKey: Register
    private let unregisterHotKey: (EventHotKeyRef?) -> OSStatus
    private var references: [Combination: EventHotKeyRef] = [:]

    init(
        register: @escaping Register = RegisterEventHotKey,
        unregister: @escaping (EventHotKeyRef?) -> OSStatus = UnregisterEventHotKey
    ) {
        registerHotKey = register
        unregisterHotKey = unregister
    }

    func register(_ modifiers: ShortcutModifiers) throws {
        var flags = 0
        for (modifier, flag) in [
            (ShortcutModifiers.control, controlKey), (.option, optionKey), (.shift, shiftKey),
            (.command, cmdKey),
        ] where modifiers.contains(modifier) {
            flags |= flag
        }
        var updated: [Combination: EventHotKeyRef] = [:]
        var acquired: [EventHotKeyRef] = []
        do {
            for (index, key) in globalShortcutKeys.enumerated() {
                // The + key also works without Shift, like the other commands.
                for extra in key == .plus && !modifiers.contains(.shift) ? [0, shiftKey] : [0] {
                    let combination = Combination(key: key.keyCode, flags: UInt32(flags | extra))
                    if let existing = references[combination] {
                        updated[combination] = existing
                        continue
                    }
                    var reference: EventHotKeyRef?
                    let result = registerHotKey(
                        combination.key, combination.flags,
                        EventHotKeyID(signature: hotKeySignature, id: UInt32(index + 1)),
                        GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
                    guard result == noErr, let reference else {
                        let effective = extra == 0 ? modifiers : modifiers.union(.shift)
                        throw result == OSStatus(eventHotKeyExistsErr)
                            ? AppFailure.shortcutUnavailable("\(effective.symbols) + \(key.name)")
                            : AppFailure.failed
                    }
                    updated[combination] = reference
                    acquired.append(reference)
                }
            }
        } catch {
            for reference in acquired { _ = unregisterHotKey(reference) }
            throw error
        }
        for (combination, reference) in references where updated[combination] == nil {
            _ = unregisterHotKey(reference)
        }
        references = updated
    }

    func unregister() {
        for reference in references.values { _ = unregisterHotKey(reference) }
        references = [:]
    }
}

extension ShortcutKey {
    fileprivate var keyCode: UInt32 {
        let code =
            switch self {
            case .space: kVK_Space
            case .up: kVK_UpArrow
            case .down: kVK_DownArrow
            case .left: kVK_LeftArrow
            case .right: kVK_RightArrow
            case .minus: kVK_ANSI_Minus
            case .plus: kVK_ANSI_Equal
            case .menuBarIcon: kVK_ANSI_H
            }
        return UInt32(code)
    }
}
