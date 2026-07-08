// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Speakit",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Speakit",
            path: "Sources/Speakit"
        )
    ]
)
