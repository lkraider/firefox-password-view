// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Keywise",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CKeywise", path: "Sources/CKeywise"),
        .executableTarget(
            name: "Keywise",
            dependencies: ["CKeywise"],
            path: "Sources/Keywise",
            linkerSettings: [
                .unsafeFlags([
                    "-L../zig-out/lib",
                    "-lkeywise",
                ])
            ]
        ),
        .testTarget(
            name: "KeywiseTests",
            dependencies: ["Keywise"],
            path: "Tests/KeywiseTests",
            linkerSettings: [
                // Only Command Line Tools is installed here (no full Xcode),
                // and swift-testing's runtime lives under its Frameworks
                // directory. The dynamic linker does not search there by
                // default.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ]
        ),
    ]
)
