// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RunGuideCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "RunGuideCore", targets: ["RunGuideCore"])
    ],
    targets: [
        .target(name: "RunGuideCore"),
        .testTarget(name: "RunGuideCoreTests", dependencies: ["RunGuideCore"])
    ]
)
