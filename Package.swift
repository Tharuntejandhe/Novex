// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Novex",
    platforms: [.macOS(.v14)],
    targets: [
        // All app logic lives in a library so it can be imported and tested
        // (executable targets can't be @testable-imported reliably).
        .target(
            name: "NovexCore",
            path: "Sources/NovexCore"
        ),
        // Thin executable: just the process entry point.
        .executableTarget(
            name: "Novex",
            dependencies: ["NovexCore"],
            path: "Sources/Novex"
        ),
        // Dependency-free test runner (no XCTest, so it runs with only the
        // Command Line Tools — no full Xcode required). Run: `swift run NovexDevTests`.
        .executableTarget(
            name: "NovexDevTests",
            dependencies: ["NovexCore"],
            path: "Sources/NovexDevTests"
        ),
    ]
)
