// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CatpawNavigation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CatpawNavigation", targets: ["CatpawNavigation"])],
    targets: [
        .target(name: "CatpawNavigation"),
        .testTarget(name: "CatpawNavigationTests", dependencies: ["CatpawNavigation"])
    ]
)
