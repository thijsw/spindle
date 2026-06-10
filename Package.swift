// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spindle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "spindle-cli", targets: ["spindle-cli"]),
        .library(name: "SpindleCore", targets: ["SpindleCore"]),
    ],
    targets: [
        // C shim isolating the IOKit CD ioctls (variadic ioctl is hostile to Swift).
        .target(name: "CIOCD"),

        .target(
            name: "DiscDrive",
            dependencies: ["CIOCD"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
            ]
        ),

        .target(name: "Metadata", dependencies: ["DiscDrive"]),

        .executableTarget(
            name: "spindle-cli",
            dependencies: ["DiscDrive", "Metadata"]
        ),

        .target(
            name: "SpindleCore",
            dependencies: ["DiscDrive", "Metadata"]
        ),

        // The CLT toolchain ships no XCTest/Swift Testing, so tests run as a
        // plain executable: `swift run spindle-tests`.
        .executableTarget(
            name: "spindle-tests",
            dependencies: ["DiscDrive", "Metadata", "SpindleCore"]
        ),
    ]
)
