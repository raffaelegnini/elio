// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "jarvisd", targets: ["jarvisd"]),
        .executable(name: "jarvis", targets: ["jarvis"]),
    ],
    targets: [
        .target(name: "JarvisCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "jarvisd", dependencies: ["JarvisCore"]),
        .executableTarget(name: "jarvis", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ],
    swiftLanguageModes: [.v5]
)
