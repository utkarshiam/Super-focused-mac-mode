// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Docket",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // The memory engine shared by the Mac app and the iPhone app (Foundation-only).
        .library(name: "MemoryKit", targets: ["MemoryKit"]),
    ],
    targets: [
        .target(
            name: "MemoryKit",
            path: "Sources/MemoryKit"
        ),
        .executableTarget(
            name: "Docket",
            dependencies: ["MemoryKit"],
            path: "Sources/Docket"
        ),
        .testTarget(
            name: "DocketTests",
            dependencies: ["Docket"],
            path: "Tests/DocketTests"
        ),
        .testTarget(
            name: "MemoryKitTests",
            dependencies: ["MemoryKit"],
            path: "Tests/MemoryKitTests"
        ),
    ]
)
