// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "catNavigation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "catNavigation", targets: ["catNavigation"])],
    targets: [
        .target(name: "catNavigation"),
        .testTarget(name: "catNavigationTests", dependencies: ["catNavigation"])
    ]
)
