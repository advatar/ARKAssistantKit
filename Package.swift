
// swift-tools-version: 5.9
import PackageDescription

/// Stores package for ARKAssistantKit in the shared Swift packages.
let package = Package(
    name: "ARKAssistantKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v15),
    ],
    products: [
        .library(name: "MCPClientKit", targets: ["MCPClientKit"]),
        .library(name: "ARKAssistantKit", targets: ["ARKAssistantKit"]),
    ],
    targets: [
        .target(
            name: "MCPClientKit",
            dependencies: []
        ),
        .target(
            name: "ARKAssistantKit",
            dependencies: ["MCPClientKit"]
        ),
        .testTarget(
            name: "MCPClientKitTests",
            dependencies: ["MCPClientKit"]
        ),
        .testTarget(
            name: "ARKAssistantKitTests",
            dependencies: ["ARKAssistantKit"]
        ),
    ]
)
