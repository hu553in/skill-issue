import Foundation

enum AppBuild {
    // Packaging marks CI release-tag builds; local Release builds remain local.
    static let releaseVersion: String? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SkillIssueReleaseBuild") as? Bool == true
        else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }()

    static let viewerSetupURL = URL(
        string: releaseVersion.map {
            "https://github.com/hu553in/skill-issue/releases/tag/v\($0)"
        } ?? "https://github.com/hu553in/skill-issue#deploy-from-a-checkout"
    )!
}
