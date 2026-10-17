import CoreGraphics
import Foundation
import Testing

@testable import SkillIssue

struct CaptureDisplayTests {
    @Test func mainDisplayFollowsTheCurrentPrimaryWithoutUsingListOrder() throws {
        let builtIn = display(1, name: "Built-in display")
        let external = display(2)
        let displays = [external, builtIn]
        let first = try DisplaySelection.main.resolve(in: displays, mainID: 1)
        #expect(first.map(\.id) == [builtIn.id])
        let changed = try DisplaySelection.main.resolve(in: displays, mainID: 2)
        #expect(changed.map(\.id) == [external.id])
        #expect(throws: AppFailure.self) {
            try DisplaySelection.main.resolve(in: displays, mainID: 3)
        }
    }

    @Test func allDisplaysTracksConnectionsAndCapturesMirrorsOnlyOnce() throws {
        let builtIn = display(1, name: "Built-in display")
        let mirror = display(2, captureID: 1)
        let external = display(3)
        let connected = try DisplaySelection.all.resolve(
            in: [mirror, external, builtIn], mainID: 1)
        #expect(Set(connected.map(\.id)) == [builtIn.id, external.id])
        #expect(connected.count == 2)
        let disconnected = try DisplaySelection.all.resolve(in: [external], mainID: 3)
        #expect(disconnected.map(\.id) == [external.id])
        let reconnected = try DisplaySelection.all.resolve(in: [external, builtIn], mainID: 3)
        #expect(Set(reconnected.map(\.id)) == [builtIn.id, external.id])
    }

    @Test func explicitSelectionUsesIdentityAcrossRenamingAndDisplayIDChanges() throws {
        let original = display(1)
        let other = display(2)
        let selection = DisplaySelection.display(original.id)
        let initial = try selection.resolve(in: [other, original], mainID: 2)
        #expect(initial.map(\.id) == [original.id])
        #expect(throws: AppFailure.self) {
            try selection.resolve(in: [other], mainID: 2)
        }
        let reconnected = display(3, id: original.id, name: "Renamed display")
        let restored = try selection.resolve(in: [other, reconnected], mainID: 2)
        #expect(restored.map(\.displayID) == [3])
        #expect(restored.map(\.name) == ["Renamed display"])
    }

    @Test func explicitMirrorKeepsItsIdentityAndUsesTheSharedCaptureTarget() throws {
        let primary = display(1, name: "Built-in display")
        let mirror = display(2, captureID: 1)
        let resolved = try DisplaySelection.display(mirror.id).resolve(
            in: [primary, mirror], mainID: 1)
        let selected = try #require(resolved.first)
        #expect(resolved.count == 1)
        #expect(selected.id == mirror.id && selected.name == mirror.name)
        #expect(selected.captureID == 1)
    }

    @Test func frozenTargetRejectsReplacementOrChangedMirrorMapping() {
        let target = display(1)
        let unrelated = display(2)
        #expect(target.isAvailable(in: [unrelated, target]))
        #expect(!target.isAvailable(in: [unrelated]))
        #expect(!target.isAvailable(in: [display(1)]))
        #expect(!target.isAvailable(in: [display(1, captureID: 2, id: target.id)]))
        #expect(!target.isAvailable(in: [display(3, id: target.id)]))
    }

    @Test(arguments: [DisplaySelection.main, .all, .display(UUID())])
    func noDisplaysFailsEverySelection(_ selection: DisplaySelection) {
        #expect(throws: AppFailure.self) {
            try selection.resolve(in: [], mainID: 0)
        }
    }

    private func display(
        _ displayID: CGDirectDisplayID, captureID: CGDirectDisplayID? = nil,
        id: UUID = UUID(), name: String = "External display"
    ) -> CaptureDisplay {
        CaptureDisplay(
            id: id, displayID: displayID, captureID: captureID ?? displayID, name: name)
    }
}
