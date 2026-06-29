package com.invisiblewrench.fluttermidicommand

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class MidiPacketParserTest {

    @Test
    fun parsesChannelMessagesWithRunningStatus() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { bytes, _ -> packets.add(bytes) }

        parser.parse(
            byteArrayOf(0x90.toByte(), 0x3C, 0x64, 0x40, 0x7F.toByte()),
            offset = 0,
            count = 5,
            timestamp = 123L,
        )

        assertEquals(2, packets.size)
        assertContentEquals(byteArrayOf(0x90.toByte(), 0x3C, 0x64), packets[0])
        assertContentEquals(
            byteArrayOf(0x90.toByte(), 0x40, 0x7F.toByte()),
            packets[1],
        )
    }

    @Test
    fun parsesSingleByteRealtimeMessages() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { bytes, _ -> packets.add(bytes) }

        parser.parse(byteArrayOf(0xF8.toByte()), offset = 0, count = 1, timestamp = 1L)

        assertEquals(1, packets.size)
        assertContentEquals(byteArrayOf(0xF8.toByte()), packets.single())
    }

    @Test
    fun repairsBackToBackSysExStartFrames() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { bytes, _ -> packets.add(bytes) }

        parser.parse(
            byteArrayOf(0xF0.toByte(), 0x01, 0x02, 0xF0.toByte(), 0x03, 0xF7.toByte()),
            offset = 0,
            count = 6,
            timestamp = 5L,
        )

        assertEquals(2, packets.size)
        assertContentEquals(
            byteArrayOf(0xF0.toByte(), 0x01, 0x02, 0xF7.toByte()),
            packets[0],
        )
        assertContentEquals(
            byteArrayOf(0xF0.toByte(), 0x03, 0xF7.toByte()),
            packets[1],
        )
    }

    @Test
    fun appliesOffsetAndCountWindow() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { bytes, _ -> packets.add(bytes) }

        parser.parse(
            byteArrayOf(0x00, 0x90.toByte(), 0x3C, 0x40, 0x00),
            offset = 1,
            count = 3,
            timestamp = 42L,
        )

        assertEquals(1, packets.size)
        assertContentEquals(byteArrayOf(0x90.toByte(), 0x3C, 0x40), packets.single())
    }
}
