import XCTest
@testable import flutter_midi_command

final class MidiPacketParserTests: XCTestCase {
    func testParsesChannelMessagesWithRunningStatus() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in
            packets.append(bytes)
        }

        parser.parse(
            data: Data([0x90, 0x3C, 0x64, 0x40, 0x7F]),
            timestamp: 123
        )

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], [0x90, 0x3C, 0x64])
        XCTAssertEqual(packets[1], [0x90, 0x40, 0x7F])
    }

    func testParsesRealtimeSingleByteMessages() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in
            packets.append(bytes)
        }

        parser.parse(data: Data([0xF8]), timestamp: 1)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0], [0xF8])
    }

    func testRepairsBackToBackSysExStartFrames() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in
            packets.append(bytes)
        }

        parser.parse(
            data: Data([0xF0, 0x01, 0x02, 0xF0, 0x03, 0xF7]),
            timestamp: 5
        )

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], [0xF0, 0x01, 0x02, 0xF7])
        XCTAssertEqual(packets[1], [0xF0, 0x03, 0xF7])
    }
}
