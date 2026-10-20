// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SummitTrainer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SummitTrainer", path: "Sources/SummitTrainer")
    ]
)
