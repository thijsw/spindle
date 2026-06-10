// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spindle",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "spindle-cli", targets: ["spindle-cli"]),
        .library(name: "SpindleCore", targets: ["SpindleCore"]),
    ],
    dependencies: [
        // MIT-licensed pure-Swift SSH/SFTP (the project's only third-party dependency).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
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

        .target(
            name: "Metadata",
            dependencies: ["DiscDrive"],
            linkerSettings: [
                .linkedFramework("DiscRecording"),
            ]
        ),

        .target(name: "RipEngine", dependencies: ["DiscDrive"]),

        .target(name: "Verification", dependencies: ["DiscDrive", "RipEngine"]),

        .target(
            name: "Transfer",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            // Citadel's types are not yet Sendable-annotated; the actor in
            // this module provides the isolation Swift 6 can't see.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .target(
            name: "Encoding",
            dependencies: ["Metadata"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
            ]
        ),

        .target(name: "Naming", dependencies: ["Metadata"]),

        .executableTarget(
            name: "spindle-cli",
            dependencies: ["DiscDrive", "Metadata", "RipEngine", "Encoding", "Naming", "Verification", "Transfer"]
        ),

        .target(
            name: "SpindleCore",
            dependencies: ["DiscDrive", "Metadata", "RipEngine", "Encoding", "Naming", "Verification", "Transfer"]
        ),

        // The CLT toolchain ships no XCTest/Swift Testing, so tests run as a
        // plain executable: `swift run spindle-tests`.
        .executableTarget(
            name: "spindle-tests",
            dependencies: ["DiscDrive", "Metadata", "RipEngine", "Encoding", "Naming", "Verification", "Transfer", "SpindleCore"]
        ),
    ]
)
