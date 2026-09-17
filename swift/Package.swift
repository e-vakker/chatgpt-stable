// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatGPTStable",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChatGPTStable", targets: ["ChatGPTStable"]),
    ],
    targets: [
        .executableTarget(
            name: "ChatGPTStable",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "ChatGPTStableTests",
            dependencies: ["ChatGPTStable"]
        ),
    ]
)
