// swift-tools-version: 6.0
import PackageDescription

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
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ]),
                .linkedFramework("Testing")
            ]
        )
    ]
)
