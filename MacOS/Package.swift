// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "0W-Tube",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "0W-Tube", targets: ["App"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [],
            path: "Sources/App"
        )
    ]
)
