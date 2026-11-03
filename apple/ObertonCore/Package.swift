// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ObertonCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ObertonCore", targets: ["ObertonCore"])],
    dependencies: [
        // Whisper speech recognition on CoreML (Settings › Speech recognition); the models are downloaded as data.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "ObertonCore", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
        .testTarget(name: "ObertonCoreTests", dependencies: ["ObertonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
