// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ObertonCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ObertonCore", targets: ["ObertonCore"])],
    dependencies: [
        // Whisper speech recognition on CoreML (Settings › Speech recognition); the models are downloaded as data.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Read aloud's Kokoro and Piper voices (the same ONNX files Windows uses), on the CPU; the models are downloaded as data.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.24.2"),
    ],
    targets: [
        .target(name: "ObertonCore", dependencies: [
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        ]),
        .testTarget(name: "ObertonCoreTests", dependencies: ["ObertonCore", .product(name: "WhisperKit", package: "WhisperKit")]),
    ],
    swiftLanguageModes: [.v5]
)
