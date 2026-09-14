// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "RepoDeck",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RepoDeckKit"),
        .target(name: "RepoDeckCore", dependencies: ["RepoDeckKit"]),
        .executableTarget(
            name: "RepoDeck",
            dependencies: ["RepoDeckKit", "RepoDeckCore"],
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(name: "RepoDeckKitTests", dependencies: ["RepoDeckKit"]),
        .testTarget(name: "RepoDeckCoreTests", dependencies: ["RepoDeckCore", "RepoDeckKit"]),
    ]
)
