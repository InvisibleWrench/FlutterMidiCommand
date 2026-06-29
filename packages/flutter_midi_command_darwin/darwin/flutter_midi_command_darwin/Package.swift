// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to
// build this package and to be recognized as a Flutter Swift Package Manager
// plugin.
import PackageDescription

let package = Package(
    name: "flutter_midi_command_darwin",
    platforms: [
        .iOS("13.1"),
        .macOS("10.15"),
    ],
    products: [
        .library(name: "flutter-midi-command-darwin", targets: ["flutter_midi_command_darwin"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "flutter_midi_command_darwin"
        ),
        .testTarget(
            name: "flutter_midi_command_darwinTests",
            dependencies: ["flutter_midi_command_darwin"]
        ),
    ]
)
