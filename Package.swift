// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Crux",
    platforms: [.macOS(.v14)],
    targets: [
        // All app logic lives in a library so it can be imported and tested
        // (executable targets can't be @testable-imported reliably).
        .target(
            name: "CruxCore",
            path: "Sources/CruxCore"
        ),
        // Thin executable: just the process entry point.
        .executableTarget(
            name: "Crux",
            dependencies: ["CruxCore"],
            path: "Sources/Crux"
        ),
        // Dependency-free test runner (no XCTest, so it runs with only the
        // Command Line Tools — no full Xcode required). Run: `swift run CruxDevTests`.
        .executableTarget(
            name: "CruxDevTests",
            dependencies: ["CruxCore"],
            path: "Sources/CruxDevTests"
        ),
    ]
)
