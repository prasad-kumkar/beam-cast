// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Beam",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Beam", targets: ["Beam"])
    ],
    targets: [
        .executableTarget(
            name: "Beam",
            path: "Sources/Beam",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "BeamTests",
            dependencies: ["Beam"],
            path: "Tests/BeamTests"
        )
    ]
)
