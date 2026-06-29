// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_midi_command",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    targets: [
        .target(
            name: "flutter_midi_command",
            path: "Classes",
            exclude: [
                "FlutterMidiCommandPlugin.m",
                "SwiftFlutterMidiCommandPlugin.swift",
                "pigeon",
            ],
            sources: ["MidiPacketParser.swift"]
        ),
        .testTarget(
            name: "MidiPacketParserTests",
            dependencies: ["flutter_midi_command"],
            path: "Tests",
            exclude: ["midi_packet_parser_smoke.swift"],
            sources: ["MidiPacketParserTests.swift"]
        ),
    ]
)
