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
    dependencies: [
        // Terminal emulator view for the built-in Terminal extension.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.20.0"),
        // In-app updates (EdDSA-signed appcast on GitHub Pages).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "SlashlightKit"),
        .target(name: "SlashlightSDK", dependencies: ["SlashlightKit"]),
        .executableTarget(name: "Slashlight", dependencies: [
            "SlashlightKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .executableTarget(name: "HelloExtension", dependencies: ["SlashlightSDK"], path: "Examples/HelloExtension"),
        .testTarget(name: "SlashlightKitTests", dependencies: ["SlashlightKit"]),
        .testTarget(name: "SlashlightTests", dependencies: ["Slashlight"]),
    ]
)
