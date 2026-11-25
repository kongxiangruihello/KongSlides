// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KongSlides",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "KongSlidesUpdateSupport"),
        .executableTarget(name: "KongSlides", dependencies: ["KongSlidesUpdateSupport"]),
        .executableTarget(name: "KongSlidesUpdater", dependencies: ["KongSlidesUpdateSupport"]),
        .testTarget(name: "KongSlidesTests", dependencies: ["KongSlides", "KongSlidesUpdateSupport"])
    ]
)
