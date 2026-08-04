// swift-tools-version: 6.0
import Foundation
import PackageDescription

let usesGitHubActions = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
let localTestingSwiftSettings: [SwiftSetting] = usesGitHubActions ? [] : [
    .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
]
let localTestingLinkerSettings: [LinkerSetting] = usesGitHubActions ? [] : [
    .unsafeFlags([
        "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
    ])
]

let package = Package(
    name: "PRReviewAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PRReviewAssistant", targets: ["PRReviewAssistant"])
    ],
    targets: [
        .executableTarget(
            name: "PRReviewAssistant",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PRReviewAssistantTests",
            dependencies: ["PRReviewAssistant"],
            swiftSettings: localTestingSwiftSettings,
            linkerSettings: localTestingLinkerSettings + [.linkedFramework("Testing")]
        )
    ]
)
