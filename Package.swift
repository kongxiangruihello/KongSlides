// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KongSlides",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "KongSlides"),
        .testTarget(name: "KongSlidesTests", dependencies: ["KongSlides"])
    ]
)
