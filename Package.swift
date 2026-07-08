// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "RepoDeck",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RepoDeckKit"),
        .executableTarget(name: "RepoDeck", dependencies: ["RepoDeckKit"]),
        .testTarget(name: "RepoDeckKitTests", dependencies: ["RepoDeckKit"]),
    ]
)
