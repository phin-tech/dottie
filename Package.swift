// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dottie",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DottieKit", targets: ["DottieKit"]),
        .executable(name: "dottie-mcp", targets: ["DottieMCP"]),
        .executable(name: "dottie", targets: ["DottieCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "a0ae212ebf6eab5f754c3129608bc5557637e605"),
    ],
    targets: [
        .target(name: "DottieKit"),
        .executableTarget(name: "DottieMCP", dependencies: [
            "DottieKit",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "DottieCLI", dependencies: ["DottieKit"]),
        .testTarget(name: "DottieKitTests", dependencies: ["DottieKit"]),
    ]
)
