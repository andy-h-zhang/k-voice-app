// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KVoiceCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "KVoiceCore",
            targets: ["KVoiceCore"]
        ),
        .executable(
            name: "speakerlab",
            targets: ["speakerlab"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // On-device speaker embeddings (WeSpeaker v2 / CoreML). Models are
        // downloaded at runtime, not vendored — see FluidAudioEmbedder.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.0")
    ],
    targets: [
        .target(
            name: "KVoiceCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .executableTarget(
            name: "speakerlab",
            dependencies: [
                "KVoiceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "KVoiceCoreTests",
            dependencies: ["KVoiceCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
