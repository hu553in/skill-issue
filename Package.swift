// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SkillIssue",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/airsidemobile/JOSESwift.git", exact: "3.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/auth0/SimpleKeychain", exact: "1.3.0"),
        .package(
            url: "https://github.com/soniqo/speech-swift.git",
            revision: "cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa"),
    ],
    targets: [
        .executableTarget(
            name: "SkillIssue",
            dependencies: [
                "JOSESwift", .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                "SimpleKeychain",
                .product(name: "NemotronStreamingASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ], path: "native", resources: [.copy("Resources")],
            swiftSettings: [.treatAllWarnings(as: .error)]),
        .testTarget(
            name: "CoreTests", dependencies: ["SkillIssue"], path: "tests",
            swiftSettings: [.treatAllWarnings(as: .error)]),
    ]
)
