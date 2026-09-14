package com.invisiblewrench.fluttermidicommand

import com.invisiblewrench.fluttermidicommand.pigeon.MidiHostDevice
import com.invisiblewrench.fluttermidicommand.pigeon.MidiPacket

/**
 * Splits a stream of MIDI bytes into complete messages.
 *
 * This is the Android half of one shared specification. `MidiPacketParser.swift` is a
 * line-for-line port, and `MidiMessageSplitter` in the platform interface package is the
 * Dart implementation; all three carry the rule numbers below and answer to the same test
 * table, so the trio can be reviewed as a diff.
 *
 * 1. System Real-Time (0xF8-0xFF) is handled first, in every state, and mutates nothing
 *    else - not the running status, not a partial message, not a SysEx in progress. It is
 *    emitted immediately, including between the data bytes of another message and from
 *    inside a SysEx. 0xF9 and 0xFD are undefined and are swallowed, but disturb no state.
 * 2. A channel voice status byte (0x80-0xEF) latches the running status, discards any
 *    incomplete message and starts a new one.
 * 3. System Common 0xF1/0xF2/0xF3 *clears* the running status and starts a new message;
 *    0xF6 clears it and is emitted immediately.
 * 4. 0xF0 clears the running status and opens a SysEx. Inside a SysEx any non-real-time
 *    status byte aborts it: a 0xF7 is synthesised, the message is emitted, and the
 *    offending byte is then re-dispatched - which generalises the back-to-back-0xF0 repair
 *    some Android stacks need. [maxSysExLength] does the same, so a device that never
 *    sends 0xF7 cannot wedge the stream.
 * 5. 0xF7 outside a SysEx, and 0xF4/0xF5, clear the running status and emit nothing. A
 *    status byte is never latched before it has been classified - the previous parser
 *    latched first, so a clock byte clobbered the running status and every subsequent
 *    running-status note was silently dropped.
 * 6. A data byte extends the message in flight, or revives the running status when there
 *    is none. A message is emitted when it reaches its expected length exactly. Data with
 *    neither is dropped.
 * 7. After an emission the partial message is cleared but the running status survives.
 * 8. [reset] clears all state.
 */
internal class MidiPacketParser(
    private val maxSysExLength: Int = DEFAULT_MAX_SYSEX_LENGTH,
    private val onPacket: (ByteArray, Long) -> Unit,
) {
    /** The last channel voice status byte, or [NO_RUNNING_STATUS]. Only ever 0x80-0xEF. */
    private var runningStatus = NO_RUNNING_STATUS

    /** The message being assembled, including its status byte. */
    private val pending = mutableListOf<Byte>()

    /** Total length [pending] must reach, or 0 when no message is in flight. */
    private var expectedLength = 0

    private var inSysEx = false
    private val sysExBuffer = mutableListOf<Byte>()

    private val sysExCap = if (maxSysExLength < 2) 2 else maxSysExLength

    fun parse(data: ByteArray, offset: Int, count: Int, timestamp: Long) {
        if (count <= 0 || offset < 0 || offset >= data.size) {
            return
        }
        val endExclusive = (offset + count).coerceAtMost(data.size)
        for (index in offset until endExclusive) {
            val midiInt = data[index].toInt() and 0xFF

            // Rule 1: System Real-Time, before anything else can touch state.
            if (midiInt >= 0xF8) {
                if (midiInt != 0xF9 && midiInt != 0xFD) {
                    onPacket(byteArrayOf(midiInt.toByte()), timestamp)
                }
                continue
            }

            if (midiInt >= 0x80) {
                handleStatusByte(midiInt, timestamp)
            } else {
                handleDataByte(midiInt, timestamp)
            }
        }
    }

    /** Drops every partial message, the running status and any SysEx in progress. */
    fun reset() {
        runningStatus = NO_RUNNING_STATUS
        pending.clear()
        expectedLength = 0
        inSysEx = false
        sysExBuffer.clear()
    }

    /** Handles a status byte in 0x80-0xF7. Real-time bytes never reach here. */
    private fun handleStatusByte(midiInt: Int, timestamp: Long) {
        if (inSysEx) {
            // Rule 4: 0xF7 terminates normally, any other status byte aborts - both close
            // the message with a 0xF7. The aborting byte is re-dispatched below.
            closeSysEx(timestamp)
            if (midiInt == 0xF7) {
                return
            }
        }

        if (midiInt < 0xF0) {
            // Rule 2: channel voice.
            runningStatus = midiInt
            startMessage(midiInt, lengthOfChannelMessage(midiInt), timestamp)
            return
        }

        // Rules 3-5: everything from 0xF0 clears the running status.
        runningStatus = NO_RUNNING_STATUS
        when (midiInt) {
            0xF0 -> {
                pending.clear()
                expectedLength = 0
                inSysEx = true
                sysExBuffer.clear()
                sysExBuffer.add(0xF0.toByte())
                capSysEx(timestamp)
            }
            // MIDI Time Code quarter frame and Song Select.
            0xF1, 0xF3 -> startMessage(midiInt, 2, timestamp)
            // Song Position Pointer.
            0xF2 -> startMessage(midiInt, 3, timestamp)
            // Tune Request.
            0xF6 -> {
                pending.clear()
                expectedLength = 0
                onPacket(byteArrayOf(0xF6.toByte()), timestamp)
            }
            // 0xF4, 0xF5 (undefined) and a stray 0xF7.
            else -> {
                pending.clear()
                expectedLength = 0
            }
        }
    }

    /** Handles a data byte, 0x00-0x7F. */
    private fun handleDataByte(midiInt: Int, timestamp: Long) {
        if (inSysEx) {
            sysExBuffer.add(midiInt.toByte())
            capSysEx(timestamp)
            return
        }

        // Rule 6: extend the message in flight, else revive the running status.
        if (expectedLength == 0) {
            if (runningStatus == NO_RUNNING_STATUS) {
                return
            }
            pending.clear()
            pending.add(runningStatus.toByte())
            expectedLength = lengthOfChannelMessage(runningStatus)
        }

        pending.add(midiInt.toByte())
        if (pending.size == expectedLength) {
            emitPending(timestamp)
        }
    }

    private fun startMessage(status: Int, length: Int, timestamp: Long) {
        pending.clear()
        pending.add(status.toByte())
        expectedLength = length
        if (pending.size == expectedLength) {
            emitPending(timestamp)
        }
    }

    // Rule 7: emit, clear the partial message, keep the running status.
    private fun emitPending(timestamp: Long) {
        onPacket(pending.toByteArray(), timestamp)
        pending.clear()
        expectedLength = 0
    }

    /** Terminates the SysEx in progress with a 0xF7 and emits it. */
    private fun closeSysEx(timestamp: Long) {
        sysExBuffer.add(0xF7.toByte())
        onPacket(sysExBuffer.toByteArray(), timestamp)
        sysExBuffer.clear()
        inSysEx = false
    }

    private fun capSysEx(timestamp: Long) {
        if (sysExBuffer.size >= sysExCap - 1) {
            closeSysEx(timestamp)
        }
    }

    private fun lengthOfChannelMessage(status: Int): Int {
        // Program Change and Channel Pressure carry one data byte; everything else in
        // 0x80-0xEF carries two.
        val midiType = status and 0xF0
        return if (midiType == 0xC0 || midiType == 0xD0) 2 else 3
    }

    private companion object {
        const val NO_RUNNING_STATUS = -1
        const val DEFAULT_MAX_SYSEX_LENGTH = 65536
    }
}

/**
 * Builds a parser that wraps each complete message as a [MidiPacket] from [device].
 *
 * The wiring seam both receivers share, so the hardware and virtual paths cannot drift
 * apart and the virtual one is testable without an Android runtime.
 */
internal fun midiPacketParserFor(
    device: MidiHostDevice,
    onDataReceived: (MidiPacket) -> Unit,
): MidiPacketParser = MidiPacketParser { bytes, timestamp ->
    onDataReceived(
        MidiPacket(
            device = device,
            data = bytes,
            timestamp = timestamp,
        ),
    )
}
