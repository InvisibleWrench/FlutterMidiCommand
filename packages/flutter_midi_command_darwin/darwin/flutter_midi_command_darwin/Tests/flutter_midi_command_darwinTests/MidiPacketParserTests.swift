import XCTest
@testable import flutter_midi_command_darwin

/// The shared conformance table. The same cases exist in `MidiPacketParserTest.kt` and
/// `midi_message_splitter_test.dart`, so the three implementations answer to one spec.
final class MidiPacketParserTests: XCTestCase {

    /// Collects every message a parser emits from one pass over `input`.
    private func parse(_ input: [UInt8], maxSysExLength: Int = 65536) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser(maxSysExLength: maxSysExLength) { bytes, _ in
            packets.append(bytes)
        }
        parser.parse(data: Data(input), timestamp: 0)
        return packets
    }

    // MARK: - Running status

    func testSplitsARunningStatusNoteOnRunIntoSeparateMessages() {
        // The core of issue #179: an M-VAVE SMK-25 sends the status byte once.
        XCTAssertEqual(
            parse([0x90, 0x3C, 0x64, 0x40, 0x7F, 0x42, 0x50]),
            [[0x90, 0x3C, 0x64], [0x90, 0x40, 0x7F], [0x90, 0x42, 0x50]]
        )
    }

    func testResolvesRunningStatusForTwoByteMessages() {
        XCTAssertEqual(
            parse([0xC0, 0x01, 0x02, 0x03]),
            [[0xC0, 0x01], [0xC0, 0x02], [0xC0, 0x03]]
        )
    }

    func testRunningStatusSurvivesAClockBetweenTwoMessages() {
        // The clock used to be latched into statusByte before its length was checked, so
        // every subsequent running-status note was silently dropped.
        XCTAssertEqual(
            parse([0x90, 0x3C, 0x64, 0xF8, 0x40, 0x7F]),
            [[0x90, 0x3C, 0x64], [0xF8], [0x90, 0x40, 0x7F]]
        )
    }

    func testRunningStatusIsClearedBySystemCommon() {
        XCTAssertEqual(
            parse([0x90, 0x3C, 0x64, 0xF1, 0x25, 0x40, 0x7F]),
            [[0x90, 0x3C, 0x64], [0xF1, 0x25]]
        )
    }

    func testDropsLeadingOrphanDataBytes() {
        XCTAssertEqual(parse([0x40, 0x7F, 0x90, 0x3C, 0x64]), [[0x90, 0x3C, 0x64]])
    }

    // MARK: - System Real-Time

    func testRealtimeIsEmittedBetweenAStatusByteAndItsData() {
        XCTAssertEqual(parse([0x90, 0xF8, 0x3C, 0x64]), [[0xF8], [0x90, 0x3C, 0x64]])
    }

    func testRealtimeIsEmittedBetweenTwoDataBytes() {
        // The clock used to be appended as data and become the velocity.
        XCTAssertEqual(parse([0x90, 0x3C, 0xFE, 0x64]), [[0xFE], [0x90, 0x3C, 0x64]])
    }

    func testParsesRealtimeSingleByteMessages() {
        XCTAssertEqual(parse([0xF8]), [[0xF8]])
    }

    func testUndefinedRealtimeBytesAreSwallowedButDisturbNothing() {
        XCTAssertEqual(
            parse([0x90, 0x3C, 0xF9, 0x64, 0xFD, 0x40, 0x7F]),
            [[0x90, 0x3C, 0x64], [0x90, 0x40, 0x7F]]
        )
    }

    // MARK: - System Common

    func testSongPositionPointerCarriesTwoDataBytes() {
        XCTAssertEqual(parse([0xF2, 0x01, 0x02]), [[0xF2, 0x01, 0x02]])
    }

    func testSongSelectCarriesOneDataByte() {
        XCTAssertEqual(parse([0xF3, 0x05]), [[0xF3, 0x05]])
    }

    func testTuneRequestIsASingleByte() {
        XCTAssertEqual(parse([0xF6]), [[0xF6]])
    }

    func testUndefinedSystemCommonEmitsNothingAndClearsRunningStatus() {
        XCTAssertEqual(parse([0x90, 0x3C, 0x64, 0xF4, 0x40, 0x7F]), [[0x90, 0x3C, 0x64]])
    }

    func testAStrayEndOfExclusiveEmitsNothingAndClearsRunningStatus() {
        XCTAssertEqual(parse([0x90, 0x3C, 0x64, 0xF7, 0x40, 0x7F]), [[0x90, 0x3C, 0x64]])
    }

    // MARK: - SysEx

    func testSysExPassesARealtimeByteThroughIntact() {
        XCTAssertEqual(
            parse([0xF0, 0x01, 0xF8, 0x02, 0xF7]),
            [[0xF8], [0xF0, 0x01, 0x02, 0xF7]]
        )
    }

    func testSysExIsAbortedByAChannelStatusByteWhichIsThenRedispatched() {
        XCTAssertEqual(
            parse([0xF0, 0x01, 0x02, 0x90, 0x3C, 0x64]),
            [[0xF0, 0x01, 0x02, 0xF7], [0x90, 0x3C, 0x64]]
        )
    }

    func testRepairsBackToBackSysExStartFrames() {
        XCTAssertEqual(
            parse([0xF0, 0x01, 0x02, 0xF0, 0x03, 0xF7]),
            [[0xF0, 0x01, 0x02, 0xF7], [0xF0, 0x03, 0xF7]]
        )
    }

    func testSysExClearsRunningStatus() {
        XCTAssertEqual(
            parse([0x90, 0x3C, 0x64, 0xF0, 0x01, 0xF7, 0x40, 0x7F]),
            [[0x90, 0x3C, 0x64], [0xF0, 0x01, 0xF7]]
        )
    }

    func testSysExIsCappedAndTheStreamRecovers() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser(maxSysExLength: 64) { bytes, _ in
            packets.append(bytes)
        }

        parser.parse(data: Data([0xF0] + [UInt8](repeating: 0x01, count: 70_000)), timestamp: 0)
        parser.parse(data: Data([0x90, 0x3C, 0x64]), timestamp: 0)

        XCTAssertEqual(packets.first?.count, 64)
        XCTAssertEqual(packets.first?.first, 0xF0)
        XCTAssertEqual(packets.first?.last, 0xF7)
        XCTAssertEqual(packets.last, [0x90, 0x3C, 0x64])
    }

    // MARK: - State across calls

    func testAMessageSplitAcrossTwoParseCallsEmitsOnce() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in packets.append(bytes) }

        parser.parse(data: Data([0x90, 0x3C]), timestamp: 0)
        XCTAssertTrue(packets.isEmpty)

        parser.parse(data: Data([0x64]), timestamp: 0)
        XCTAssertEqual(packets, [[0x90, 0x3C, 0x64]])
    }

    func testResetMidMessageEmitsNothing() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in packets.append(bytes) }

        parser.parse(data: Data([0x90, 0x3C]), timestamp: 0)
        parser.reset()
        parser.parse(data: Data([0x64]), timestamp: 0)

        XCTAssertTrue(packets.isEmpty)
    }

    func testStampsMessagesWithTheTimestampOfTheCompletingCall() {
        var timestamps: [UInt64] = []
        let parser = MidiPacketParser { _, timestamp in timestamps.append(timestamp) }

        parser.parse(data: Data([0x90, 0x3C]), timestamp: 10)
        parser.parse(data: Data([0x64, 0x40, 0x7F]), timestamp: 20)

        XCTAssertEqual(timestamps, [20, 20])
    }
}
