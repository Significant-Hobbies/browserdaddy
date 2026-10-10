// swift-tools-version: 6.0
import PackageDescription
import Foundation

let sparkleTestFrameworks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64").path

let package = Package(
    name: "BrowserDaddy",
    // v15 floor: Scene.defaultLaunchBehavior(.suppressed) needs 15 —
    // the URL-handler route must never flash a window (SceneBuilder
    // cannot branch on runtime availability).
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .executable(name: "BrowserDaddy", targets: ["BrowserDaddy"]),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"), .package(url: "https://github.com/sass-maker/ui-library", from: "0.1.14")],
    targets: [
        .target(name: "BrowserCore"),
        .executableTarget(
            name: "BrowserDaddy",
            dependencies: [.product(name: "SaaSMakerUI", package: "ui-library"), "BrowserCore", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources/StorageDaddy.png", "Resources/PageDoodles.png"],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserDaddyTests", dependencies: ["BrowserDaddy"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", sparkleTestFrameworks])]),
    ]
)
