// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GateOpener",
    platforms: [
        .macOS(.v14),
        .iOS(.v18)
    ],
    products: [
        .executable(name: "GateOpener", targets: ["GateOpener"]),
        .library(name: "GateOpenerCore", targets: ["GateOpenerCore"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "GateOpener",
            dependencies: ["GateOpenerCore"]
        ),
        .target(
            name: "GateOpenerCore"
        ),
        .testTarget(
            name: "GateOpenerCoreTests",
            dependencies: ["GateOpenerCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
