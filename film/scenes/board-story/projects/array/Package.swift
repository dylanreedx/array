// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Array",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Array", targets: ["Array"])],
    targets: [
        .executableTarget(name: "Array", path: "Sources/Array"),
        .testTarget(name: "ArrayTests", dependencies: ["Array"], path: "Tests/ArrayTests"),
    ]
)
