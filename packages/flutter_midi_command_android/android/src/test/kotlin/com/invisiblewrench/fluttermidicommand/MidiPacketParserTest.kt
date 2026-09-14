package com.invisiblewrench.fluttermidicommand

import com.invisiblewrench.fluttermidicommand.pigeon.MidiDeviceType
import com.invisiblewrench.fluttermidicommand.pigeon.MidiHostDevice
import com.invisiblewrench.fluttermidicommand.pigeon.MidiPacket
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The shared conformance table. The same cases exist in `MidiPacketParserTests.swift` and
 * `midi_message_splitter_test.dart`, so the three implementations answer to one spec.
 */
class MidiPacketParserTest {

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    /** Collects every message a parser emits from one pass over [input]. */
    private fun parse(vararg input: Int, maxSysExLength: Int = 65536): List<List<Int>> {
        val packets = mutableListOf<List<Int>>()
        val parser = MidiPacketParser(maxSysExLength) { data, _ ->
            packets.add(data.map { it.toInt() and 0xFF })
        }
        val array = bytes(*input)
        parser.parse(array, offset = 0, count = array.size, timestamp = 0L)
        return packets
    }

    private fun expect(vararg messages: List<Int>) = messages.toList()

    // --- Running status ---------------------------------------------------------------

    @Test
    fun splitsARunningStatusNoteOnRunIntoSeparateMessages() {
        // The core of issue #179: an M-VAVE SMK-25 sends the status byte once.
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64), listOf(0x90, 0x40, 0x7F), listOf(0x90, 0x42, 0x50)),
            parse(0x90, 0x3C, 0x64, 0x40, 0x7F, 0x42, 0x50),
        )
    }

    @Test
    fun resolvesRunningStatusForTwoByteMessages() {
        assertEquals(
            expect(listOf(0xC0, 0x01), listOf(0xC0, 0x02), listOf(0xC0, 0x03)),
            parse(0xC0, 0x01, 0x02, 0x03),
        )
    }

    @Test
    fun runningStatusSurvivesAClockBetweenTwoMessages() {
        // The clock used to be latched into statusByte before its length was checked, so
        // every subsequent running-status note was silently dropped.
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64), listOf(0xF8), listOf(0x90, 0x40, 0x7F)),
            parse(0x90, 0x3C, 0x64, 0xF8, 0x40, 0x7F),
        )
    }

    @Test
    fun runningStatusIsClearedBySystemCommon() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64), listOf(0xF1, 0x25)),
            parse(0x90, 0x3C, 0x64, 0xF1, 0x25, 0x40, 0x7F),
        )
    }

    @Test
    fun dropsLeadingOrphanDataBytes() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64)),
            parse(0x40, 0x7F, 0x90, 0x3C, 0x64),
        )
    }

    // --- System Real-Time -------------------------------------------------------------

    @Test
    fun realtimeIsEmittedBetweenAStatusByteAndItsData() {
        assertEquals(
            expect(listOf(0xF8), listOf(0x90, 0x3C, 0x64)),
            parse(0x90, 0xF8, 0x3C, 0x64),
        )
    }

    @Test
    fun realtimeIsEmittedBetweenTwoDataBytes() {
        // The clock used to be appended as data and become the velocity.
        assertEquals(
            expect(listOf(0xFE), listOf(0x90, 0x3C, 0x64)),
            parse(0x90, 0x3C, 0xFE, 0x64),
        )
    }

    @Test
    fun parsesSingleByteRealtimeMessages() {
        assertEquals(expect(listOf(0xF8)), parse(0xF8))
    }

    @Test
    fun undefinedRealtimeBytesAreSwallowedButDisturbNothing() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64), listOf(0x90, 0x40, 0x7F)),
            parse(0x90, 0x3C, 0xF9, 0x64, 0xFD, 0x40, 0x7F),
        )
    }

    // --- System Common ----------------------------------------------------------------

    @Test
    fun songPositionPointerCarriesTwoDataBytes() {
        assertEquals(expect(listOf(0xF2, 0x01, 0x02)), parse(0xF2, 0x01, 0x02))
    }

    @Test
    fun songSelectCarriesOneDataByte() {
        assertEquals(expect(listOf(0xF3, 0x05)), parse(0xF3, 0x05))
    }

    @Test
    fun tuneRequestIsASingleByte() {
        assertEquals(expect(listOf(0xF6)), parse(0xF6))
    }

    @Test
    fun undefinedSystemCommonEmitsNothingAndClearsRunningStatus() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64)),
            parse(0x90, 0x3C, 0x64, 0xF4, 0x40, 0x7F),
        )
    }

    @Test
    fun aStrayEndOfExclusiveEmitsNothingAndClearsRunningStatus() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64)),
            parse(0x90, 0x3C, 0x64, 0xF7, 0x40, 0x7F),
        )
    }

    // --- SysEx ------------------------------------------------------------------------

    @Test
    fun sysExPassesARealtimeByteThroughIntact() {
        assertEquals(
            expect(listOf(0xF8), listOf(0xF0, 0x01, 0x02, 0xF7)),
            parse(0xF0, 0x01, 0xF8, 0x02, 0xF7),
        )
    }

    @Test
    fun sysExIsAbortedByAChannelStatusByteWhichIsThenRedispatched() {
        assertEquals(
            expect(listOf(0xF0, 0x01, 0x02, 0xF7), listOf(0x90, 0x3C, 0x64)),
            parse(0xF0, 0x01, 0x02, 0x90, 0x3C, 0x64),
        )
    }

    @Test
    fun repairsBackToBackSysExStartFrames() {
        assertEquals(
            expect(listOf(0xF0, 0x01, 0x02, 0xF7), listOf(0xF0, 0x03, 0xF7)),
            parse(0xF0, 0x01, 0x02, 0xF0, 0x03, 0xF7),
        )
    }

    @Test
    fun sysExClearsRunningStatus() {
        assertEquals(
            expect(listOf(0x90, 0x3C, 0x64), listOf(0xF0, 0x01, 0xF7)),
            parse(0x90, 0x3C, 0x64, 0xF0, 0x01, 0xF7, 0x40, 0x7F),
        )
    }

    @Test
    fun sysExIsCappedAndTheStreamRecovers() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser(maxSysExLength = 64) { data, _ -> packets.add(data) }

        val runaway = ByteArray(70_001)
        runaway[0] = 0xF0.toByte()
        for (index in 1 until runaway.size) {
            runaway[index] = 0x01
        }
        parser.parse(runaway, offset = 0, count = runaway.size, timestamp = 0L)
        parser.parse(bytes(0x90, 0x3C, 0x64), offset = 0, count = 3, timestamp = 0L)

        assertEquals(64, packets.first().size)
        assertEquals(0xF0.toByte(), packets.first().first())
        assertEquals(0xF7.toByte(), packets.first().last())
        assertContentEquals(bytes(0x90, 0x3C, 0x64), packets.last())
    }

    // --- State across calls -----------------------------------------------------------

    @Test
    fun aMessageSplitAcrossTwoParseCallsEmitsOnce() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { data, _ -> packets.add(data) }

        parser.parse(bytes(0x90, 0x3C), offset = 0, count = 2, timestamp = 0L)
        assertTrue(packets.isEmpty())

        parser.parse(bytes(0x64), offset = 0, count = 1, timestamp = 0L)
        assertContentEquals(bytes(0x90, 0x3C, 0x64), packets.single())
    }

    @Test
    fun resetMidMessageEmitsNothing() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { data, _ -> packets.add(data) }

        parser.parse(bytes(0x90, 0x3C), offset = 0, count = 2, timestamp = 0L)
        parser.reset()
        parser.parse(bytes(0x64), offset = 0, count = 1, timestamp = 0L)

        assertTrue(packets.isEmpty())
    }

    @Test
    fun appliesOffsetAndCountWindow() {
        val packets = mutableListOf<ByteArray>()
        val parser = MidiPacketParser { data, _ -> packets.add(data) }

        parser.parse(
            bytes(0x00, 0x90, 0x3C, 0x40, 0x00),
            offset = 1,
            count = 3,
            timestamp = 42L,
        )

        assertEquals(1, packets.size)
        assertContentEquals(bytes(0x90, 0x3C, 0x40), packets.single())
    }

    @Test
    fun stampsMessagesWithTheTimestampOfTheCompletingCall() {
        val timestamps = mutableListOf<Long>()
        val parser = MidiPacketParser { _, timestamp -> timestamps.add(timestamp) }

        parser.parse(bytes(0x90, 0x3C), offset = 0, count = 2, timestamp = 10L)
        parser.parse(bytes(0x64, 0x40, 0x7F), offset = 0, count = 3, timestamp = 20L)

        assertEquals(listOf(20L, 20L), timestamps)
    }

    // --- The wiring seam both receivers share -----------------------------------------

    @Test
    fun midiPacketParserForWrapsEachMessageAsAPacketFromTheDevice() {
        val device = MidiHostDevice(
            id = "FlutterMidiCommand_Virtual",
            name = "FlutterMidiCommand_Virtual",
            type = MidiDeviceType.OWN_VIRTUAL,
            connected = true,
            inputs = null,
            outputs = null,
        )
        val packets = mutableListOf<MidiPacket>()
        val parser = midiPacketParserFor(device) { packets.add(it) }

        // The virtual receiver used to forward this slice raw, so running status reached
        // apps unresolved.
        parser.parse(bytes(0x90, 0x3C, 0x64, 0x40, 0x7F), offset = 0, count = 5, timestamp = 7L)

        assertEquals(2, packets.size)
        assertContentEquals(bytes(0x90, 0x3C, 0x64), packets[0].data)
        assertContentEquals(bytes(0x90, 0x40, 0x7F), packets[1].data)
        assertEquals(device.id, packets[0].device?.id)
        assertEquals(7L, packets[0].timestamp)
    }
}
