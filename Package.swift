// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MySpotlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MySpotlight", targets: ["MySpotlight"]),
        // The public extension API. Built-ins and third-party extensions both subclass `Extension` from here.
        .library(name: "SpotlightKit", targets: ["SpotlightKit"]),
        // Runs a `SpotlightKit.Extension` as a separate process speaking JSON over stdin/stdout.
        .library(name: "SpotlightSDK", targets: ["SpotlightSDK"]),
        .executable(name: "hello-extension", targets: ["HelloExtension"]),
    ],
    targets: [
        .target(name: "SpotlightKit"),
        .target(name: "SpotlightSDK", dependencies: ["SpotlightKit"]),
        .executableTarget(name: "MySpotlight", dependencies: ["SpotlightKit"]),
        .executableTarget(name: "HelloExtension", dependencies: ["SpotlightSDK"], path: "Examples/HelloExtension"),
    ]
)
