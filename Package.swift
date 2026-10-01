// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
        .executable(name: "jarvisd", targets: ["jarvisd"]),
        .executable(name: "jarvis", targets: ["jarvis"]),
        .executable(name: "JarvisApp", targets: ["JarvisApp"]),
    ],
    targets: [
        .target(name: "JarvisCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "jarvisd", dependencies: ["JarvisCore"]),
        .executableTarget(name: "jarvis", dependencies: ["JarvisCore"]),
        .target(name: "JarvisVoice", dependencies: ["JarvisCore"]),
        .executableTarget(name: "JarvisApp", dependencies: ["JarvisCore", "JarvisVoice"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ],
    swiftLanguageModes: [.v5]
)
