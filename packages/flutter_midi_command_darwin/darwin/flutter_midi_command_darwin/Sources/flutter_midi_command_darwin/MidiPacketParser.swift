import Foundation

final class MidiPacketParser {
    private enum ParserState {
        case header
        case params
        case sysex
    }

    private var parserState: ParserState = .header
    private var sysExBuffer: [UInt8] = []
    private var midiBuffer: [UInt8] = []
    private var midiPacketLength: Int = 0
    private var statusByte: UInt8 = 0
    private let onPacket: (_ bytes: [UInt8], _ timestamp: UInt64) -> Void

    init(onPacket: @escaping (_ bytes: [UInt8], _ timestamp: UInt64) -> Void) {
        self.onPacket = onPacket
    }

    func parse(data: Data, timestamp: UInt64) {
        guard !data.isEmpty else {
            return
        }

        for midiByte in data {
            let midiInt = Int(midiByte & 0xFF)

            switch parserState {
            case .header:
                if midiInt == 0xF0 {
                    parserState = .sysex
                    sysExBuffer.removeAll(keepingCapacity: true)
                    sysExBuffer.append(midiByte)
                } else if (midiInt & 0x80) == 0x80 {
                    statusByte = midiByte
                    midiPacketLength = lengthOfMessageType(type: statusByte)
                    guard midiPacketLength > 0 else {
                        parserState = .header
                        continue
                    }
                    midiBuffer.removeAll(keepingCapacity: true)
                    midiBuffer.append(midiByte)
                    parserState = .params
                    finalizeMessageIfComplete(timestamp: timestamp)
                } else if statusByte != 0 {
                    midiPacketLength = lengthOfMessageType(type: statusByte)
                    guard midiPacketLength > 1 else {
                        parserState = .header
                        continue
                    }
                    midiBuffer.removeAll(keepingCapacity: true)
                    midiBuffer.append(statusByte)
                    midiBuffer.append(midiByte)
                    parserState = .params
                    finalizeMessageIfComplete(timestamp: timestamp)
                }

            case .sysex:
                if midiInt == 0xF0 {
                    // Some stacks emit back-to-back SysEx starts without a closing F7.
                    sysExBuffer.append(0xF7)
                    onPacket(sysExBuffer, timestamp)
                    sysExBuffer.removeAll(keepingCapacity: true)
                }
                sysExBuffer.append(midiByte)
                if midiInt == 0xF7 {
                    onPacket(sysExBuffer, timestamp)
                    parserState = .header
                }

            case .params:
                midiBuffer.append(midiByte)
                finalizeMessageIfComplete(timestamp: timestamp)
            }
        }
    }

    private func finalizeMessageIfComplete(timestamp: UInt64) {
        if midiPacketLength > 0 && midiBuffer.count == midiPacketLength {
            onPacket(midiBuffer, timestamp)
            parserState = .header
        }
    }

    private func lengthOfMessageType(type: UInt8) -> Int {
        let midiType = type & 0xF0

        switch type {
        case 0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFF, 0xFE:
            return 1
        case 0xF1, 0xF3:
            return 2
        case 0xF2:
            return 3
        default:
            break
        }

        switch midiType {
        case 0xC0, 0xD0:
            return 2
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0:
            return 3
        default:
            return 0
        }
    }
}
