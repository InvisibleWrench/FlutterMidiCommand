import Foundation

@main
struct MidiPacketParserSmoke {
    @inline(__always)
    static func assertOrExit(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("Assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        var packets: [[UInt8]] = []
        let parser = MidiPacketParser { bytes, _ in
            packets.append(bytes)
        }

        parser.parse(data: Data([0x90, 0x3C, 0x64, 0x40, 0x7F]), timestamp: 1)
        assertOrExit(packets.count == 2, "running status packet count")
        assertOrExit(packets[0] == [0x90, 0x3C, 0x64], "running status first packet")
        assertOrExit(packets[1] == [0x90, 0x40, 0x7F], "running status second packet")

        packets.removeAll(keepingCapacity: true)
        parser.parse(data: Data([0xF0, 0x01, 0x02, 0xF0, 0x03, 0xF7]), timestamp: 2)
        assertOrExit(packets.count == 2, "sysex packet count")
        assertOrExit(packets[0] == [0xF0, 0x01, 0x02, 0xF7], "sysex first packet")
        assertOrExit(packets[1] == [0xF0, 0x03, 0xF7], "sysex second packet")
    }
}
