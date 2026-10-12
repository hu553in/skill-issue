import Foundation

final class TestDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() {
        super.init(suiteName: "skill-issue-tests")!
    }
    override func string(forKey defaultName: String) -> String? {
        lock.withLock { values[defaultName] as? String }
    }
    override func integer(forKey defaultName: String) -> Int {
        lock.withLock { values[defaultName] as? Int ?? 0 }
    }
    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }
    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }
}
