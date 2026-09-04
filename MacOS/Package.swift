// swift-tools-version:5.9
import PackageDescription
import Foundation

let moduleCache = NSString(string: "~/Library/Caches/0W-Tube/ModuleCache")
    .expandingTildeInPath

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
            path: "Sources/App",
            swiftSettings: [
                .sharedModuleCache(moduleCache),
                .typeCheckDiagnostics()
            ]
        )
    ]
)

extension SwiftSetting {
    static func sharedModuleCache(_ path: String) -> SwiftSetting {
        .unsafeFlags(["-module-cache-path", path])
    }

    static func typeCheckDiagnostics() -> SwiftSetting {
        .unsafeFlags([
            "-Xfrontend", "-warn-long-function-bodies=50",
            "-Xfrontend", "-warn-long-expression-type-checking=50"
        ], .when(configuration: .release))
    }
}
