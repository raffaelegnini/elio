// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Elio",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ElioCore", targets: ["ElioCore"]),
        .executable(name: "eliod", targets: ["eliod"]),
        .executable(name: "elio", targets: ["elio"]),
        .executable(name: "ElioApp", targets: ["ElioApp"]),
    ],
    targets: [
        .target(name: "ElioCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "eliod", dependencies: ["ElioCore"]),
        .executableTarget(name: "elio", dependencies: ["ElioCore"]),
        .target(name: "ElioVoice", dependencies: ["ElioCore"]),
        .executableTarget(name: "ElioApp", dependencies: ["ElioCore", "ElioVoice"]),
        .executableTarget(name: "voicesim", dependencies: ["ElioCore", "ElioVoice"]),
        .testTarget(name: "ElioCoreTests", dependencies: ["ElioCore"]),
    ],
    swiftLanguageModes: [.v5]
)
