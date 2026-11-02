// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ObertonCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ObertonCore", targets: ["ObertonCore"])],
    targets: [
        .target(name: "ObertonCore"),
        .testTarget(name: "ObertonCoreTests", dependencies: ["ObertonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
