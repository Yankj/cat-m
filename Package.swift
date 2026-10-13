// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CatCompanion",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CatCompanion", targets: ["CatCompanion"])
    ],
    targets: [
        .target(
            name: "CatCompanion",
            path: "CatCompanion"
        )
    ]
)
