// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CatpawImageComposer", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CatpawImageComposer", targets: ["CatpawImageComposer"])],
    targets: [.target(name: "CatpawImageComposer"),
              .testTarget(name: "CatpawImageComposerTests", dependencies: ["CatpawImageComposer"])])
