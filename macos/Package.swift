// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FirefoxPasswordView",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CFfpw", path: "Sources/CFfpw"),
        .executableTarget(
            name: "FirefoxPasswordView",
            dependencies: ["CFfpw"],
            path: "Sources/FirefoxPasswordView",
            linkerSettings: [
                .unsafeFlags([
                    "-L../zig-out/lib",
                    "-lffpw",
                    "-lsqlite3",
                ])
            ]
        ),
        .testTarget(
            name: "FirefoxPasswordViewTests",
            dependencies: ["FirefoxPasswordView"],
            path: "Tests/FirefoxPasswordViewTests",
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
