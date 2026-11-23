// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DmainAdmin",
    platforms: [.macOS(.v15)],
    products: [.library(name: "DmainAdminCore", targets: ["DmainAdminCore"])],
    targets: [
        // Runs dmain and decodes what it sends; no UI, so it host-tests.
        .target(name: "DmainAdminCore"),
        // Views and their previews. Previews need this target's scheme selected:
        // an executable target cannot preview.
        .target(name: "DmainAdminUI", dependencies: ["DmainAdminCore"]),
        .executableTarget(name: "DmainAdmin", dependencies: ["DmainAdminUI", "DmainAdminCore"]),
        .testTarget(name: "DmainAdminCoreTests", dependencies: ["DmainAdminCore"]),
    ]
)
