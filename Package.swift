// swift-tools-version: 5.9
import PackageDescription

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
    ]
)

