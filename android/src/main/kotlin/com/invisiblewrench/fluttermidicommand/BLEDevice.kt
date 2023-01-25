package com.invisiblewrench.fluttermidicommand

import android.bluetooth.*
import android.os.Handler
import android.util.Log
import com.invisiblewrench.fluttermidicommand.FlutterMidiCommandPlugin.Companion.characteristicUUID
import com.invisiblewrench.fluttermidicommand.FlutterMidiCommandPlugin.Companion.serviceUUID
import com.welie.blessed.BluetoothPeripheral
import com.welie.blessed.BluetoothPeripheralCallback
import com.welie.blessed.GattStatus
import com.welie.blessed.WriteType
import io.flutter.plugin.common.MethodChannel.Result
import kotlin.math.min

class BLEDevice  : Device {

    var peripheral: BluetoothPeripheral
    var result:Result? = null
    private var dataStreamHandler: FMCStreamHandler
    private var characteristic : BluetoothGattCharacteristic? = null

    constructor(peripheral: BluetoothPeripheral, setupStreamHandler: FMCStreamHandler, streamHandler: FMCStreamHandler, connectResult:Result?) : super(peripheral.address, "BLE", peripheral.name) {
        this.peripheral = peripheral
        this.setupStreamHandler = setupStreamHandler
        this.dataStreamHandler = streamHandler

        Log.d("FlutterMIDICommand","connect ble device ${peripheral.address}")

        this.result = connectResult
    }

    fun Byte.toPositiveInt() = toInt() and 0xFF

    override fun send(data: ByteArray, timestamp: Long?) {
        Log.d("FlutterMIDICommand", "Send data to MIDI device [${data.joinToString { "%02x".format(it) }}]")
        if (characteristic != null) {

            var packetSize = peripheral.getMaximumWriteValueLength(WriteType.WITHOUT_RESPONSE)
//            Log.d("FlutterMIDICommand", "Packetsize: $packetSize")

            var dataBytes = data.toMutableList()

            if (data.first().toPositiveInt() == 0xF0 && data.last().toPositiveInt() == 0xF7) { //  this is a sysex message, handle carefully
                if (data.size > packetSize-3) { // Split into multiple messages of 20 bytes total
                    Log.d("FlutterMIDICommand", "Multi packet SysEx")

//                    Log.d("FlutterMIDICommand", "Databytes: [${dataBytes.joinToString { "%02x".format(it) }}]")
                    // First packet
                    var packet = dataBytes.slice(IntRange(0, packetSize-3)).toMutableList()

                    // Insert header(and empty timstamp high) and timestamp low in front Sysex Start
                    packet.add(0, 0x80.toByte())
                    packet.add(0, 0x80.toByte())

                    sendPacket(packet.toByteArray())

                    dataBytes = dataBytes.subList(packetSize-2, dataBytes.size)

//                    Log.d("FlutterMIDICommand", "Databytes: [${dataBytes.joinToString { "%02x".format(it) }}]")

                    // More packets
                    while (dataBytes.size > 0) {

                        var pickCount = min(dataBytes.size, packetSize-1)
                        packet = dataBytes.subList(0, pickCount) // Pick bytes for packet

                        // Insert header
                        packet.add(0, 0x80.toByte())

                        if (packet.size < packetSize) { // Last packet
                            // Timestamp before Sysex End byte
                            packet.add(packet.size-1, 0x80.toByte())
                        }

                        // Wait for buffer to clear
//                        Log.d("FlutterMIDICommand", "Other Packet: [${packet.joinToString { "%02x".format(it) }}]")
                        sendPacket(packet.toByteArray())

                        if (dataBytes.size > packetSize-2) {
                            dataBytes = dataBytes.subList(pickCount, dataBytes.size) // Advance buffer
                        }
                        else {
                            return
                        }
                    }
                } else {
//                    Log.d("FlutterMIDICommand", "Single packet SysEx")
                    // Insert timestamp low in front of Sysex End-byte
                    dataBytes.add(data.size-1, 0x80.toByte())

                    // Insert header(and empty timstamp high) and timestamp low in front of BLE Midi message
                    dataBytes.add(0, 0x80.toByte())
                    dataBytes.add(0, 0x80.toByte())

                    sendPacket(dataBytes.toByteArray())
                }
                return
            }

            // In bluetooth MIDI we need to send each midi command separately
            var currentBuffer = mutableListOf<Byte>()
            for (i in 0 until dataBytes.size) {
                var byte = dataBytes[i]

//                Log.d("FlutterMIDICommand", "Add byte $byte to buffer [${currentBuffer.joinToString { "%02x".format(it) }}]")

                // Insert header(and empty timstamp high) and timestamp
                // low in front of BLE Midi message
                if((byte.toPositiveInt() and 0x80) != 0){
                    currentBuffer.add(0, 0x80.toByte())
                    currentBuffer.add(0, 0x80.toByte())
            }
                currentBuffer.add(byte)

                // Send each MIDI command separately
                var endReached = i == (dataBytes.size - 1)
                var isCompleteCommand = endReached || (dataBytes[i+1].toPositiveInt() and 0x80) != 0

                if(isCompleteCommand){
                    sendPacket(currentBuffer.toByteArray())
                    currentBuffer.clear()
                }
            }

        }
    }

    private fun sendPacket(data: ByteArray) {
        Log.d("FlutterMIDICommand","send ble packet [${data.joinToString { "%02x".format(it) }}]")
        peripheral.writeCharacteristic(characteristic!!, data, WriteType.WITHOUT_RESPONSE)

    }

    override fun close() {
        Log.d("FlutterMIDICommand", "Close  BLE device ${name}")
        peripheral.cancelConnection()
        setupStreamHandler?.send("deviceDisconnected")
    }


    val peripheralCallback: BluetoothPeripheralCallback =
        object : BluetoothPeripheralCallback() {

            override fun onServicesDiscovered(peripheral: BluetoothPeripheral) {
                Log.d("FlutterMIDICommand","onServicesDiscovered")

                // Start to listen for notfications, this might trigger bonding on Pixels
                Log.d("FlutterMIDICommand", "Enable notify on MIDI characteristic")
                peripheral.setNotify(serviceUUID, characteristicUUID, true)

                characteristic = peripheral.getCharacteristic(serviceUUID, characteristicUUID)
            }

            override fun onNotificationStateUpdate(
                peripheral: BluetoothPeripheral,
                characteristic: BluetoothGattCharacteristic,
                status: GattStatus
            ) {
                if (status === GattStatus.SUCCESS) {
                    val isNotifying: Boolean = peripheral.isNotifying(characteristic)
                    Log.d("FlutterMIDICommand","SUCCESS: Notify set to $isNotifying for ${characteristic.uuid}");

                    if (isNotifying) {
                        Log.d("FlutterMIDICommand", "BLE device connected create BLEDevice instance ${peripheral.name}")

//                        Handler().postDelayed({
                            Log.d("FlutterMIDICommand", "CONNECTED")
                            result?.success(null)
                            setupStreamHandler?.send("deviceConnected")
//                        }, 1000)

                    }

                } else {
                    Log.d("FlutterMIDICommand","ERROR: Changing notification state failed for ${characteristic.uuid} ($status)");
                }
            }

            override fun onCharacteristicUpdate(
                peripheral: BluetoothPeripheral,
                value: ByteArray,
                characteristic: BluetoothGattCharacteristic,
                status: GattStatus
            ) {
                if (status !== GattStatus.SUCCESS) return
                val characteristicUUID = characteristic.uuid
//                Log.d("FlutterMIDICommand", "Update value from ${characteristicUUID}: $status")
                parseBLEPacket(value)
            }

            override fun onMtuChanged(peripheral: BluetoothPeripheral, mtu: Int, status: GattStatus) {
                Log.d("FlutterMIDICommand","new MTU set: $mtu")
            }

            override fun onBondingStarted(peripheral: BluetoothPeripheral) {
                Log.d("FlutterMIDICommand","onBondingStarted")
            }

            override fun onBondingSucceeded(peripheral: BluetoothPeripheral) {
                Log.d("FlutterMIDICommand","onBondingSucceded")
                setupStreamHandler?.send("deviceBonded")
            }

            override fun onBondingFailed(peripheral: BluetoothPeripheral) {
                Log.d("FlutterMIDICommand","onBondingFailed - disconnect")
                peripheral.cancelConnection()
            }

            override fun onBondLost(peripheral: BluetoothPeripheral) {
                Log.d("FlutterMIDICommand","onBondLost")
            }

            override fun onConnectionUpdated(
                peripheral: BluetoothPeripheral,
                interval: Int,
                latency: Int,
                timeout: Int,
                status: GattStatus
            ) {
                Log.d("FlutterMIDICommand","onConnectionUpdated status $status")
            }
        }


    // BLE MIDI parsing
    enum class BLE_HANDLER_STATE
    {
        HEADER,
        TIMESTAMP,
        STATUS,
        STATUS_RUNNING,
        PARAMS,
        SYSTEM_RT,
        SYSEX,
        SYSEX_END,
        SYSEX_INT,
    }

    var bleHandlerState = BLE_HANDLER_STATE.HEADER

    var sysExBuffer = mutableListOf<Byte>()
    var timestamp:Long = 0
    var bleMidiBuffer = mutableListOf<Byte>()
    var bleMidiPacketLength:Int = 0
    var bleSysExHasFinished:Boolean = true

    private fun parseBLEPacket(packet: ByteArray) {
        Log.d("FlutterMIDICommand","parse packet [${packet.joinToString { "%02x".format(it) }}]")

        if (packet.isNotEmpty())
        {

            if (packet.size == 1 && packet[0].toPositiveInt() == 0xF7 && !bleSysExHasFinished) {
                sysExBuffer.add(packet[0])
                Log.d("FlutterMIDICommand","pre finalize sysex ${ sysExBuffer.joinToString { "%02x".format(it)}}")
                createMessageEvent(sysExBuffer, 0)
                return;
            }

            // parse BLE message
            bleHandlerState = BLE_HANDLER_STATE.HEADER

            var header:Byte = packet[0]
            var statusByte:Int = 0


            for (i in 1 until packet.size) {

                var midiByte:Int = packet[i].toPositiveInt()

                if ((((midiByte and 0x80) == 0x80) && (bleHandlerState != BLE_HANDLER_STATE.TIMESTAMP)) && (bleHandlerState != BLE_HANDLER_STATE.SYSEX_INT)) {
//                    Log.d("FlutterMIDICommand","midiByte is 0x80")
                    if (!bleSysExHasFinished) {
                        if ((midiByte and 0xF7) == 0xF7)
                        { // Sysex end
//                            Log.d("FlutterMIDICommand","sysex end on byte $midiByte")
                            bleSysExHasFinished = true
                            bleHandlerState = BLE_HANDLER_STATE.SYSEX_END
                        } else {
//                            Log.d("FlutterMIDICommand","Set to SYSEX_INT")
                            bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT
                        }
                    } else {
                        bleHandlerState = BLE_HANDLER_STATE.TIMESTAMP
                    }
                } else {
//                    Log.d("FlutterMIDICommand","handle state")
                    // State handling
                    when (bleHandlerState)
                    {
                        BLE_HANDLER_STATE.HEADER -> {
                            if (!bleSysExHasFinished) {
                                if ((midiByte and 0x80) == 0x80)
                                { // System messages can interrupt ongoing sysex
                                    bleHandlerState = BLE_HANDLER_STATE.SYSEX_INT
                                }
                                else
                                {
                                    // Sysex continue
//                                    Log.d("FlutterMIDICommand","sysex continue")
                                    bleHandlerState = BLE_HANDLER_STATE.SYSEX
                                }
                            }
                        }

                        BLE_HANDLER_STATE.TIMESTAMP -> {
                            if ((midiByte and 0xFF) == 0xF0) { // Sysex start
                                bleSysExHasFinished = false
                                sysExBuffer.clear()
                                bleHandlerState = BLE_HANDLER_STATE.SYSEX
                            } else if ((midiByte and 0x80) == 0x80) { // Status/System start
//                                Log.d("FlutterMIDICommand","switch to status")
                                bleHandlerState = BLE_HANDLER_STATE.STATUS
                            } else {
                                bleHandlerState = BLE_HANDLER_STATE.STATUS_RUNNING
                            }
                        }

                        BLE_HANDLER_STATE.STATUS -> {
                            bleHandlerState = BLE_HANDLER_STATE.PARAMS
                        }

                        BLE_HANDLER_STATE.STATUS_RUNNING -> {
                            bleHandlerState = BLE_HANDLER_STATE.PARAMS
                        }

                        BLE_HANDLER_STATE.PARAMS -> { // After params can come TSlow or more params
                        }

                        BLE_HANDLER_STATE.SYSEX -> {
                        }

                        BLE_HANDLER_STATE.SYSEX_INT -> {
                            if ((midiByte and 0xF7) == 0xF7) { // Sysex end
//                                Log.d("FlutterMIDICommand","sysex end")
                                bleSysExHasFinished = true
                                bleHandlerState = BLE_HANDLER_STATE.SYSEX_END
                            } else {
//                                Log.d("FlutterMIDICommand","State -> SYSTEM_RT byte: $midiByte")
                                bleHandlerState = BLE_HANDLER_STATE.SYSTEM_RT
                            }
                        }

                        BLE_HANDLER_STATE.SYSTEM_RT -> {
                            if (!bleSysExHasFinished) { // Continue incomplete Sysex
//                                Log.d("FlutterMIDICommand","Continue incomplete Sysex")
                                bleHandlerState = BLE_HANDLER_STATE.SYSEX
                            }
                        }

                        else -> {
                            Log.d("FlutterMIDICommand","Unhandled state $bleHandlerState")
                        }
                    }
                }

//                Log.d("FlutterMIDICommand","Handle data with status $bleHandlerState")

                // Data handling
                when (bleHandlerState)
                {
                BLE_HANDLER_STATE.TIMESTAMP -> {
//                print ("set timestamp")
                    var tsHigh:Int = header.toPositiveInt() and 0x3f
                    var tsLow:Int = midiByte and 0x7f
                    timestamp = ((tsHigh shl 7) or tsLow).toLong()
                }

                BLE_HANDLER_STATE.STATUS -> {
//                    Log.d("FlutterMIDICommand","status $bleHandlerState")
                    bleMidiPacketLength = lengthOfMessageType(midiByte)
                    bleMidiBuffer.clear()
                    bleMidiBuffer.add(midiByte.toByte())

                    if (bleMidiPacketLength == 1) {
                        createMessageEvent(
                            bleMidiBuffer,
                             timestamp
                        ) // TODO Add timestamp
                    } else {
//                    print ("set status")
                        statusByte = midiByte
                    }
                }

                BLE_HANDLER_STATE.STATUS_RUNNING -> {
//                    Log.d("FlutterMIDICommand","set running status")
                    bleMidiPacketLength = lengthOfMessageType(statusByte)
                    bleMidiBuffer.clear()
                    bleMidiBuffer.add(statusByte.toByte())
                    bleMidiBuffer.add(midiByte.toByte())

                    if (bleMidiPacketLength == 2) {
                        createMessageEvent(
                            bleMidiBuffer,
                             timestamp
                        )
                    }
                }

                BLE_HANDLER_STATE.PARAMS -> {
//                    Log.d("FlutterMIDICommand","add param $midiByte")

                    bleMidiBuffer.add(midiByte.toByte())

                    if (bleMidiPacketLength == bleMidiBuffer.size) {
//                        Log.d("FlutterMIDICommand","msg complete buffer:  ${ bleMidiBuffer.joinToString { "%02x".format(it)}}")
                        createMessageEvent(
                            bleMidiBuffer,
                             timestamp
                        )
                        bleMidiBuffer = bleMidiBuffer.subList(0, 1) // Remove all but status, which might be used for running msgs
                    }
                }

                BLE_HANDLER_STATE.SYSTEM_RT -> {
//                    Log.d("FlutterMIDICommand","handle RT")
                    createMessageEvent(listOf(midiByte.toByte()), timestamp)
                }

                BLE_HANDLER_STATE.SYSEX -> {
                    sysExBuffer.add(midiByte.toByte())
                }

                BLE_HANDLER_STATE.SYSEX_INT -> {
//                print("sysex int")
                }

                BLE_HANDLER_STATE.SYSEX_END -> {
                    sysExBuffer.add(midiByte.toByte())
//                    Log.d("FlutterMIDICommand","finalize sysex ${ sysExBuffer.joinToString { "%02x".format(it)}}")
                    createMessageEvent(sysExBuffer, 0)
                }

                else -> {
                    Log.d("FlutterMIDICommand", "Unhandled state (data) $bleHandlerState")
                }
            }
            }
        }
    }


    fun createMessageEvent(packet: List<Byte>, timestamp:Long) {
        Log.d("FlutterMIDICommand","rx event ${packet.joinToString { "%02x".format(it) }}")
        val deviceInfo = mapOf("id" to peripheral.address, "name" to peripheral.name, "type" to "BLE")
        dataStreamHandler.send( mapOf("data" to packet.toList(), "timestamp" to timestamp, "device" to deviceInfo))
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


