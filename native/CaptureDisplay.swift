import AppKit
import ColorSync

enum DisplaySelection: RawRepresentable, Hashable, Sendable {
    case main, all
    case display(UUID)

    init?(rawValue: String) {
        switch rawValue {
        case "main": self = .main
        case "all": self = .all
        default:
            guard let id = UUID(uuidString: rawValue) else { return nil }
            self = .display(id)
        }
    }

    var rawValue: String {
        switch self {
        case .main: return "main"
        case .all: return "all"
        case .display(let id): return id.uuidString
        }
    }

    func resolve(in displays: [CaptureDisplay], mainID: CGDirectDisplayID) throws
        -> [CaptureDisplay]
    {
        guard !displays.isEmpty else { throw AppFailure.noDisplays }
        switch self {
        case .main:
            guard let display = displays.first(where: { $0.displayID == mainID }) else {
                throw AppFailure.displayUnavailable
            }
            return [display]
        case .all:
            // A mirrored desktop is captured once, with the primary display's identity.
            let ordered =
                displays.filter { $0.displayID == $0.captureID }
                + displays.filter { $0.displayID != $0.captureID }
            var captured = Set<CGDirectDisplayID>()
            return ordered.filter { captured.insert($0.captureID).inserted }
        case .display(let id):
            guard let display = displays.first(where: { $0.id == id }) else {
                throw AppFailure.displayUnavailable
            }
            return [display]
        }
    }
}

struct CaptureDisplay: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayID: CGDirectDisplayID
    let captureID: CGDirectDisplayID
    var name: String

    func isAvailable(in displays: [Self]) -> Bool {
        displays.contains { $0.id == id && $0.captureID == captureID }
    }

    @MainActor
    static func available() -> [Self] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &identifiers, &count) == .success else { return [] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let id = screen.cgDirectDisplayID { names[id] = screen.localizedName }
        }
        var displays = identifiers.prefix(Int(count)).compactMap { identifier -> Self? in
            guard let reference = CGDisplayCreateUUIDFromDisplayID(identifier),
                let id = UUID(
                    uuidString: CFUUIDCreateString(nil, reference.takeRetainedValue()) as String)
            else { return nil }
            let mirror = CGDisplayMirrorsDisplay(identifier)
            return Self(
                id: id, displayID: identifier,
                captureID: mirror == kCGNullDirectDisplay ? identifier : mirror,
                name: names[identifier]
                    ?? (CGDisplayIsBuiltin(identifier) != 0 ? "Built-in display" : "Display"))
        }
        let main = CGMainDisplayID()
        displays.sort {
            if ($0.displayID == main) != ($1.displayID == main) { return $0.displayID == main }
            return $0.id.uuidString < $1.id.uuidString
        }
        let counts = Dictionary(grouping: displays, by: \.name).mapValues(\.count)
        var occurrences: [String: Int] = [:]
        for index in displays.indices {
            let name = displays[index].name
            if counts[name, default: 0] > 1 {
                occurrences[name, default: 0] += 1
                displays[index].name = "\(name) (\(occurrences[name, default: 0]))"
            }
        }
        return displays
    }
}
