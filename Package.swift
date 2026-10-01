// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Official ONNX Runtime build (scripts/fetch-onnxruntime.sh), self-contained and bundled in the app.
let ort = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("vendor/onnxruntime").path

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
        // Speaker verification runs on ONNX Runtime (bundled into the app by build-app.sh).
        .target(
            name: "CSpeaker",
            cSettings: [.unsafeFlags(["-I\(ort)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(ort)/lib", "-lonnxruntime",
                                           "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "\(ort)/lib"])]
        ),
        .target(name: "ElioVoice", dependencies: ["ElioCore", "CSpeaker"]),
        .executableTarget(name: "ElioApp", dependencies: ["ElioCore", "ElioVoice"]),
        .executableTarget(name: "voicesim", dependencies: ["ElioCore", "ElioVoice"]),
        .testTarget(name: "ElioCoreTests", dependencies: ["ElioCore"]),
    ],
    swiftLanguageModes: [.v5]
)
