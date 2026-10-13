// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dottie",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DottieKit", targets: ["DottieKit"])],
    targets: [
        .target(name: "DottieKit"),
        .testTarget(name: "DottieKitTests", dependencies: ["DottieKit"]),
    ]
)
