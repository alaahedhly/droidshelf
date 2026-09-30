// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dropo", targets: ["Dropo"]),
        .library(name: "DropoCore", targets: ["DropoCore"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        .target(
            name: "DropoCore",
            dependencies: ["CLibMTP"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Dropo",
            dependencies: ["DropoCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DropoCoreTests",
            dependencies: ["DropoCore"]
        ),
    ]
)
