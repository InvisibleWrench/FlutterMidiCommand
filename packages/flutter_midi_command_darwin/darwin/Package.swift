// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_midi_command_darwin",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "flutter-midi-command-darwin", targets: ["flutter_midi_command_darwin"])
    ],
    targets: [
        .target(
            name: "flutter_midi_command_darwin",
            path: "Classes",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "flutter_midi_command_darwin_tests",
            dependencies: ["flutter_midi_command_darwin"],
            path: "Tests"
        )
    ]
)
