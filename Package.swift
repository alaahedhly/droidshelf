// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Droidshelf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Droidshelf", targets: ["Droidshelf"]),
        .library(name: "DroidshelfCore", targets: ["DroidshelfCore"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        .target(
            name: "DroidshelfCore",
            dependencies: ["CLibMTP"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Droidshelf",
            dependencies: ["DroidshelfCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "DroidshelfCoreTests",
            dependencies: ["DroidshelfCore"]
        ),
    ]
)
