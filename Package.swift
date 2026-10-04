// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Docket",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Docket",
            path: "Sources/Docket"
        ),
        .testTarget(
            name: "DocketTests",
            dependencies: ["Docket"],
            path: "Tests/DocketTests"
        ),
    ]
)
