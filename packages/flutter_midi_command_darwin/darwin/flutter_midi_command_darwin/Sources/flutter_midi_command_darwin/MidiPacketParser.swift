import Foundation

/// Splits a stream of MIDI bytes into complete messages.
///
/// This is the Darwin half of one shared specification. `MidiPacketParser.kt` is a
/// line-for-line port, and `MidiMessageSplitter` in the platform interface package is the
/// Dart implementation; all three carry the rule numbers below and answer to the same test
/// table, so the trio can be reviewed as a diff.
///
/// 1. System Real-Time (0xF8-0xFF) is handled first, in every state, and mutates nothing
///    else - not the running status, not a partial message, not a SysEx in progress. It is
///    emitted immediately, including between the data bytes of another message and from
///    inside a SysEx. 0xF9 and 0xFD are undefined and are swallowed, but disturb no state.
/// 2. A channel voice status byte (0x80-0xEF) latches the running status, discards any
///    incomplete message and starts a new one.
/// 3. System Common 0xF1/0xF2/0xF3 *clears* the running status and starts a new message;
///    0xF6 clears it and is emitted immediately.
/// 4. 0xF0 clears the running status and opens a SysEx. Inside a SysEx any non-real-time
///    status byte aborts it: a 0xF7 is synthesised, the message is emitted, and the
///    offending byte is then re-dispatched - which generalises the back-to-back-0xF0
///    repair some stacks need. `maxSysExLength` does the same, so a device that never
///    sends 0xF7 cannot wedge the stream.
/// 5. 0xF7 outside a SysEx, and 0xF4/0xF5, clear the running status and emit nothing. A
///    status byte is never latched before it has been classified - the previous parser
///    latched first, so a clock byte clobbered the running status and every subsequent
///    running-status note was silently dropped.
/// 6. A data byte extends the message in flight, or revives the running status when there
///    is none. A message is emitted when it reaches its expected length exactly. Data with
///    neither is dropped.
/// 7. After an emission the partial message is cleared but the running status survives.
/// 8. `reset()` clears all state.
final class MidiPacketParser {
    private static let defaultMaxSysExLength = 65536

    /// The last channel voice status byte, or nil. Only ever holds 0x80-0xEF.
    private var runningStatus: UInt8?

    /// The message being assembled, including its status byte.
    private var pending: [UInt8] = []

    /// Total length `pending` must reach, or 0 when no message is in flight.
    private var expectedLength: Int = 0

    private var inSysEx = false
    private var sysExBuffer: [UInt8] = []

    private let sysExCap: Int
    private let onPacket: (_ bytes: [UInt8], _ timestamp: UInt64) -> Void

    init(
        maxSysExLength: Int = MidiPacketParser.defaultMaxSysExLength,
        onPacket: @escaping (_ bytes: [UInt8], _ timestamp: UInt64) -> Void
    ) {
        self.sysExCap = maxSysExLength < 2 ? 2 : maxSysExLength
        self.onPacket = onPacket
    }

    func parse(data: Data, timestamp: UInt64) {
        guard !data.isEmpty else {
            return
        }

        for midiByte in data {
            // Rule 1: System Real-Time, before anything else can touch state.
            if midiByte >= 0xF8 {
                if midiByte != 0xF9 && midiByte != 0xFD {
                    onPacket([midiByte], timestamp)
                }
                continue
            }

            if midiByte >= 0x80 {
                handleStatusByte(midiByte, timestamp: timestamp)
            } else {
                handleDataByte(midiByte, timestamp: timestamp)
            }
        }
    }

    /// Drops every partial message, the running status and any SysEx in progress.
    func reset() {
        runningStatus = nil
        pending.removeAll(keepingCapacity: true)
        expectedLength = 0
        inSysEx = false
        sysExBuffer.removeAll(keepingCapacity: true)
    }

    /// Handles a status byte in 0x80-0xF7. Real-time bytes never reach here.
    private func handleStatusByte(_ midiByte: UInt8, timestamp: UInt64) {
        if inSysEx {
            // Rule 4: 0xF7 terminates normally, any other status byte aborts - both close
            // the message with a 0xF7. The aborting byte is re-dispatched below.
            closeSysEx(timestamp: timestamp)
            if midiByte == 0xF7 {
                return
            }
        }

        if midiByte < 0xF0 {
            // Rule 2: channel voice.
            runningStatus = midiByte
            startMessage(midiByte, length: lengthOfChannelMessage(midiByte), timestamp: timestamp)
            return
        }

        // Rules 3-5: everything from 0xF0 clears the running status.
        runningStatus = nil
        switch midiByte {
        case 0xF0:
            pending.removeAll(keepingCapacity: true)
            expectedLength = 0
            inSysEx = true
            sysExBuffer.removeAll(keepingCapacity: true)
            sysExBuffer.append(0xF0)
            capSysEx(timestamp: timestamp)
        // MIDI Time Code quarter frame and Song Select.
        case 0xF1, 0xF3:
            startMessage(midiByte, length: 2, timestamp: timestamp)
        // Song Position Pointer.
        case 0xF2:
            startMessage(midiByte, length: 3, timestamp: timestamp)
        // Tune Request.
        case 0xF6:
            pending.removeAll(keepingCapacity: true)
            expectedLength = 0
            onPacket([0xF6], timestamp)
        // 0xF4, 0xF5 (undefined) and a stray 0xF7.
        default:
            pending.removeAll(keepingCapacity: true)
            expectedLength = 0
        }
    }

    /// Handles a data byte, 0x00-0x7F.
    private func handleDataByte(_ midiByte: UInt8, timestamp: UInt64) {
        if inSysEx {
            sysExBuffer.append(midiByte)
            capSysEx(timestamp: timestamp)
            return
        }

        // Rule 6: extend the message in flight, else revive the running status.
        if expectedLength == 0 {
            guard let status = runningStatus else {
                return
            }
            pending.removeAll(keepingCapacity: true)
            pending.append(status)
            expectedLength = lengthOfChannelMessage(status)
        }

        pending.append(midiByte)
        if pending.count == expectedLength {
            emitPending(timestamp: timestamp)
        }
    }

    private func startMessage(_ status: UInt8, length: Int, timestamp: UInt64) {
        pending.removeAll(keepingCapacity: true)
        pending.append(status)
        expectedLength = length
        if pending.count == expectedLength {
            emitPending(timestamp: timestamp)
        }
    }

    // Rule 7: emit, clear the partial message, keep the running status.
    private func emitPending(timestamp: UInt64) {
        onPacket(pending, timestamp)
        pending.removeAll(keepingCapacity: true)
        expectedLength = 0
    }

    /// Terminates the SysEx in progress with a 0xF7 and emits it.
    private func closeSysEx(timestamp: UInt64) {
        sysExBuffer.append(0xF7)
        onPacket(sysExBuffer, timestamp)
        sysExBuffer.removeAll(keepingCapacity: true)
        inSysEx = false
    }

    private func capSysEx(timestamp: UInt64) {
        if sysExBuffer.count >= sysExCap - 1 {
            closeSysEx(timestamp: timestamp)
        }
    }

    private func lengthOfChannelMessage(_ status: UInt8) -> Int {
        // Program Change and Channel Pressure carry one data byte; everything else in
        // 0x80-0xEF carries two.
        let midiType = status & 0xF0
        return (midiType == 0xC0 || midiType == 0xD0) ? 2 : 3
    }
}
