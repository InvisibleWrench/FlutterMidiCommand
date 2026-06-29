package com.invisiblewrench.fluttermidicommand

internal class MidiPacketParser(
    private val onPacket: (ByteArray, Long) -> Unit,
) {
    private enum class ParserState {
        HEADER,
        PARAMS,
        SYSEX,
    }

    private var parserState = ParserState.HEADER
    private val sysExBuffer = mutableListOf<Byte>()
    private val midiBuffer = mutableListOf<Byte>()
    private var midiPacketLength = 0
    private var statusByte: Byte = 0

    fun parse(data: ByteArray, offset: Int, count: Int, timestamp: Long) {
        if (count <= 0 || offset < 0 || offset >= data.size) {
            return
        }
        val endExclusive = (offset + count).coerceAtMost(data.size)
        for (index in offset until endExclusive) {
            val midiByte = data[index]
            val midiInt = midiByte.toInt() and 0xFF

            when (parserState) {
                ParserState.HEADER -> {
                    if (midiInt == 0xF0) {
                        parserState = ParserState.SYSEX
                        sysExBuffer.clear()
                        sysExBuffer.add(midiByte)
                    } else if ((midiInt and 0x80) == 0x80) {
                        // Regular status byte.
                        statusByte = midiByte
                        midiPacketLength = lengthOfMessageType(midiInt)
                        if (midiPacketLength <= 0) {
                            parserState = ParserState.HEADER
                            continue
                        }
                        midiBuffer.clear()
                        midiBuffer.add(midiByte)
                        parserState = ParserState.PARAMS
                        finalizeMessageIfComplete(timestamp)
                    } else if (statusByte != 0.toByte()) {
                        // Running status uses the latest status byte.
                        midiPacketLength = lengthOfMessageType(statusByte.toInt() and 0xFF)
                        if (midiPacketLength <= 1) {
                            parserState = ParserState.HEADER
                            continue
                        }
                        midiBuffer.clear()
                        midiBuffer.add(statusByte)
                        midiBuffer.add(midiByte)
                        parserState = ParserState.PARAMS
                        finalizeMessageIfComplete(timestamp)
                    }
                }

                ParserState.SYSEX -> {
                    if (midiInt == 0xF0) {
                        // Some Android stacks can emit back-to-back SysEx starts without a closing F7.
                        // Close the previous frame and start a new one.
                        sysExBuffer.add(0xF7.toByte())
                        onPacket(sysExBuffer.toByteArray(), timestamp)
                        sysExBuffer.clear()
                    }
                    sysExBuffer.add(midiByte)
                    if (midiInt == 0xF7) {
                        onPacket(sysExBuffer.toByteArray(), timestamp)
                        parserState = ParserState.HEADER
                    }
                }

                ParserState.PARAMS -> {
                    midiBuffer.add(midiByte)
                    finalizeMessageIfComplete(timestamp)
                }
            }
        }
    }

    private fun finalizeMessageIfComplete(timestamp: Long) {
        if (midiPacketLength > 0 && midiBuffer.size == midiPacketLength) {
            onPacket(midiBuffer.toByteArray(), timestamp)
            parserState = ParserState.HEADER
        }
    }

    private fun lengthOfMessageType(type: Int): Int {
        val midiType = type and 0xF0

        when (type) {
            0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFF, 0xFE -> return 1
            0xF1, 0xF3 -> return 2
            0xF2 -> return 3
        }

        when (midiType) {
            0xC0, 0xD0 -> return 2
            0x80, 0x90, 0xA0, 0xB0, 0xE0 -> return 3
        }
        return 0
    }
}
