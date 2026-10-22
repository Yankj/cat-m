// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "catImageComposer", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "catImageComposer", targets: ["catImageComposer"])],
    targets: [.target(name: "catImageComposer"),
              .testTarget(name: "catImageComposerTests", dependencies: ["catImageComposer"])])
