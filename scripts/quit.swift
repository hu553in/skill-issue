import AppKit

let plist =
    try PropertyListSerialization.propertyList(
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
        format: nil
    )
guard let identifier = plist as? [String: Any],
    let bundleID = identifier["CFBundleIdentifier"] as? String
else {
    throw CocoaError(.propertyListReadCorrupt)
}
for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
    fputs("Confirm Quit in Skill Issue to continue rebuilding.\n", stderr)
    guard app.terminate() || app.isTerminated else {
        fputs("Quit Skill Issue before rebuilding.\n", stderr)
        exit(1)
    }
    let deadline = Date().addingTimeInterval(120)
    while !app.isTerminated && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard app.isTerminated else {
        fputs(
            "Skill Issue has not quit. Confirm Quit if prompted, then wait for it to close and retry.\n",
            stderr)
        exit(1)
    }
}
