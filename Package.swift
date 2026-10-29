// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slashlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Slashlight", targets: ["Slashlight"]),
        // The public extension API. Built-ins and third-party extensions both subclass `Extension` from here.
        .library(name: "SlashlightKit", targets: ["SlashlightKit"]),
        // Runs a `SlashlightKit.Extension` as a separate process speaking JSON over stdin/stdout.
        .library(name: "SlashlightSDK", targets: ["SlashlightSDK"]),
        .executable(name: "hello-extension", targets: ["HelloExtension"]),
    ],
    targets: [
        .target(name: "SlashlightKit"),
        .target(name: "SlashlightSDK", dependencies: ["SlashlightKit"]),
        .executableTarget(name: "Slashlight", dependencies: ["SlashlightKit"]),
        .executableTarget(name: "HelloExtension", dependencies: ["SlashlightSDK"], path: "Examples/HelloExtension"),
    ]
)
