// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "NotchViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CZlib", path: "Sources/CZlib", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "NotchViewer", dependencies: ["CZlib"], path: "Sources/NotchViewer"),
    ]
)
