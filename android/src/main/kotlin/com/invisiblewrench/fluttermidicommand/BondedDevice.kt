package com.invisiblewrench.fluttermidicommand

import android.bluetooth.*
import android.content.Context
import android.media.midi.MidiReceiver
import android.util.Log
import io.flutter.plugin.common.MethodChannel.Result

class BondedDevice  : Device {

    lateinit var device: BluetoothDevice
    lateinit var context: Context

    var socket: BluetoothSocket? = null
    constructor(device: BluetoothDevice, context: Context) : super(device.address, "Bonded") {
        this.device = device
        this.context = context

        device.fetchUuidsWithSdp()
    }
    override fun connectWithStreamHandler(streamHandler: FMCStreamHandler, connectResult:Result?) {
        Log.d("FlutterMIDICommand","connect bonded")

        this.setupStreamHandler = streamHandler

        Log.d("FlutterMIDICommand","bonded UUIds ${device.uuids}")

        this.receiver = receiver

        connectResult.success(null)
    }


    override fun send(data: ByteArray, timestamp: Long?) {

    }

    override fun close() {


        Log.d("FlutterMIDICommand", "Close  bondede device ${this.device}")
        socket?.close()

        setupStreamHandler?.send("deviceDisconnected")
    }
}

class BondedReceiver(stream: FMCStreamHandler, device: BluetoothDevice) : MidiReceiver() {
    val stream = stream
    val deviceInfo = mapOf("id" to device.address, "name" to device.name, "type" to "Bonded")

    // MIDI parsing
    enum class PARSER_STATE
    {
        HEADER,
        PARAMS,
        SYSEX,
    }

    var parserState = PARSER_STATE.HEADER

    var sysExBuffer = mutableListOf<Byte>()
    var midiBuffer = mutableListOf<Byte>()
    var midiPacketLength:Int = 0
    var statusByte:Byte = 0

    override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
        msg?.also {
            var data = it.slice(IntRange(offset, offset + count - 1))
//        Log.d("FlutterMIDICommand", "data sliced $data offset $offset count $count")

            if (data.size > 0) {
                for (i in 0 until data.size) {
                    var midiByte: Byte = data[i]
                    var midiInt = midiByte.toInt() and 0xFF

//          Log.d("FlutterMIDICommand", "parserState $parserState byte $midiByte")

                    when (parserState) {
                        PARSER_STATE.HEADER -> {
                            if (midiInt == 0xF0) {
                                parserState = PARSER_STATE.SYSEX
                                sysExBuffer.clear()
                                sysExBuffer.add(midiByte)
                            } else if (midiInt and 0x80 == 0x80) {
                                // some kind of midi msg
                                statusByte = midiByte
                                midiPacketLength = lengthOfMessageType(midiInt)
//                Log.d("FlutterMIDICommand", "expected length $midiPacketLength")
                                midiBuffer.clear()
                                midiBuffer.add(midiByte)
                                parserState = PARSER_STATE.PARAMS
                                finalizeMessageIfComplete(timestamp)
                            } else {
                                // in header state but no status byte, do running status
                                midiBuffer.clear()
                                midiBuffer.add(statusByte)
                                midiBuffer.add(midiByte)
                                parserState = PARSER_STATE.PARAMS
                                finalizeMessageIfComplete(timestamp)
                            }
                        }

                        PARSER_STATE.SYSEX -> {
                            if (midiInt == 0xF0) {
                                // Android can skip SysEx end bytes, when more sysex messages are coming in succession.
                                // in an attempt to save the situation, add an end byte to the current buffer and start a new one.
                                sysExBuffer.add(0xF7.toByte())
//                Log.d("FlutterMIDICommand", "sysex force finalized $sysExBuffer")
                                stream.send(
                                    mapOf(
                                        "data" to sysExBuffer.toList(),
                                        "timestamp" to timestamp,
                                        "device" to deviceInfo
                                    )
                                )
                                sysExBuffer.clear();
                            }
                            sysExBuffer.add(midiByte)
                            if (midiInt == 0xF7) {
                                // Sysex complete
//                Log.d("FlutterMIDICommand", "sysex complete $sysExBuffer")
                                stream.send(
                                    mapOf(
                                        "data" to sysExBuffer.toList(),
                                        "timestamp" to timestamp,
                                        "device" to deviceInfo
                                    )
                                )
                                parserState = PARSER_STATE.HEADER
                            }
                        }

                        PARSER_STATE.PARAMS -> {
                            midiBuffer.add(midiByte)
                            finalizeMessageIfComplete(timestamp)
                        }
                    }
                }
            }
        }
    }

    fun finalizeMessageIfComplete(timestamp: Long) {
        if (midiBuffer.size == midiPacketLength) {
//        Log.d("FlutterMIDICommand", "status complete $midiBuffer")
            stream.send( mapOf("data" to midiBuffer.toList(), "timestamp" to timestamp, "device" to deviceInfo))
            parserState = PARSER_STATE.HEADER
        }
    }

    fun lengthOfMessageType(type:Int): Int {
        var midiType:Int = type and 0xF0

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

