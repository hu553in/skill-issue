import Carbon
import Testing

@testable import SkillIssue

@MainActor
private final class HotKeySystem {
    struct Registration: Equatable {
        let key: UInt32
        let flags: UInt32
        let id: UInt32
        let options: OptionBits
    }
    var active: [EventHotKeyRef: Registration] = [:]
    var conflict: (key: UInt32, flags: UInt32)?
    var failure: OSStatus = OSStatus(eventHotKeyExistsErr)
    var attempts = 0
    var removed: [EventHotKeyRef] = []

    func makeHotKeys() -> CarbonHotKeys {
        CarbonHotKeys(
            register: { [self] key, flags, id, _, options, output in
                attempts += 1
                if let conflict, conflict.key == key && conflict.flags == flags { return failure }
                if active.values.contains(where: { $0.key == key && $0.flags == flags }) {
                    return OSStatus(eventHotKeyExistsErr)
                }
                let reference = EventHotKeyRef(bitPattern: attempts)!
                active[reference] = Registration(
                    key: key, flags: flags, id: id.id, options: options)
                output?.pointee = reference
                return noErr
            },
            unregister: { [self] reference in
                guard let reference, active.removeValue(forKey: reference) != nil else {
                    Issue.record("Attempted to unregister a reference that is not active.")
                    return OSStatus(paramErr)
                }
                removed.append(reference)
                return noErr
            })
    }
}

@MainActor
struct GlobalShortcutsTests {
    @Test func registrationIsExclusiveAndUnchangedSetsAreNotRegisteredAgain() throws {
        let system = HotKeySystem()
        let hotKeys = system.makeHotKeys()
        try hotKeys.register(.standard)
        let original = system.active
        #expect(original.count == 9)
        #expect(original.values.allSatisfy { $0.options == UInt32(kEventHotKeyExclusive) })
        #expect(Set(original.values.map(\.id)) == Set(1...8))
        let plus = original.values.filter { $0.key == UInt32(kVK_ANSI_Equal) }
        #expect(
            Set(plus.map(\.flags)) == [
                UInt32(controlKey | optionKey | cmdKey),
                UInt32(controlKey | optionKey | shiftKey | cmdKey),
            ])
        try hotKeys.register(.standard)
        #expect(system.attempts == 9 && system.active == original && system.removed.isEmpty)
        hotKeys.unregister()
        #expect(system.active.isEmpty && system.removed.count == 9)
        hotKeys.unregister()
        #expect(system.removed.count == 9)
    }

    @Test(arguments: [kVK_Space, kVK_DownArrow, kVK_ANSI_Minus])
    func failedReplacementKeepsEveryOldShortcutAndReleasesCandidates(key: Int) throws {
        let system = HotKeySystem()
        let hotKeys = system.makeHotKeys()
        try hotKeys.register(.standard)
        let original = system.active
        system.conflict = (UInt32(key), UInt32(controlKey | shiftKey))
        #expect(throws: AppFailure.self) { try hotKeys.register([.control, .shift]) }
        #expect(system.active == original)
        #expect(system.removed.allSatisfy { original[$0] == nil })
        system.conflict = nil
        try hotKeys.register([.control, .shift])
        #expect(system.active.count == 8)
        #expect(system.active.values.allSatisfy { $0.flags == UInt32(controlKey | shiftKey) })
        #expect(original.keys.allSatisfy { system.removed.contains($0) })
        hotKeys.unregister()
        #expect(system.active.isEmpty)
    }

    @Test func replacementReusesTheOverlappingShiftedPlus() throws {
        let system = HotKeySystem()
        let hotKeys = system.makeHotKeys()
        try hotKeys.register(.standard)
        let shared = try #require(
            system.active.first {
                $0.value.key == UInt32(kVK_ANSI_Equal)
                    && $0.value.flags == UInt32(controlKey | optionKey | shiftKey | cmdKey)
            }?.key)
        try hotKeys.register([.control, .option, .shift, .command])
        #expect(system.active.count == 8 && system.active[shared] != nil)
        #expect(system.attempts == 16 && system.removed.count == 8)
        try hotKeys.register(.standard)
        #expect(system.active.count == 9 && system.active[shared] != nil)
        #expect(!system.removed.contains(shared))
        hotKeys.unregister()
        #expect(system.active.isEmpty)
    }

    @Test func startupFailureUnwindsAndReportsTheActualShiftAlias() {
        let system = HotKeySystem()
        let hotKeys = system.makeHotKeys()
        system.conflict = (
            UInt32(kVK_ANSI_Equal), UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        do {
            try hotKeys.register(.standard)
            Issue.record("A conflicting shortcut was accepted.")
        } catch AppFailure.shortcutUnavailable(let chord) {
            #expect(chord == "⌃⌥⇧⌘ + Plus")
        } catch {
            Issue.record("A shortcut conflict was not reported as a conflict.")
        }
        #expect(system.active.isEmpty && system.removed.count == 7)
        system.failure = OSStatus(paramErr)
        do {
            try hotKeys.register(.standard)
            Issue.record("A failed registration was accepted.")
        } catch AppFailure.failed {
        } catch {
            Issue.record("An OS failure was incorrectly reported as a shortcut conflict.")
        }
        #expect(system.active.isEmpty && system.removed.count == 14)
    }
}
