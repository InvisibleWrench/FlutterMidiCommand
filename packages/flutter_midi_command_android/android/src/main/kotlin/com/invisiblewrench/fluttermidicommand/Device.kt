package com.invisiblewrench.fluttermidicommand

import android.bluetooth.BluetoothDevice
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiReceiver

abstract class Device {
    var id:String
    var type:String
    lateinit var midiDevice: MidiDevice
    protected var receiver:MidiReceiver? = null

    constructor(id: String, type: String) {
        this.id = id
        this.type = type
    }

    abstract fun connect()

    abstract fun send(data: ByteArray, timestamp: Long?)

    abstract fun close()

    companion object {
        private const val PORT_SUFFIX = "#port="

        fun deviceIdForInfo(info: MidiDeviceInfo): String {
            var isBluetoothDevice = info.type == MidiDeviceInfo.TYPE_BLUETOOTH
            var deviceId: String = if (isBluetoothDevice) (info.properties.get(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE) as BluetoothDevice).address else info.id.toString()
            return deviceId
        }

        fun logicalDeviceId(baseId: String, portIndex: Int): String {
            return "$baseId$PORT_SUFFIX$portIndex"
        }

        fun baseDeviceId(logicalId: String): String {
            return logicalId.substringBefore(PORT_SUFFIX)
        }

        fun portIndex(logicalId: String): Int {
            return logicalId.substringAfter(PORT_SUFFIX, "0").toIntOrNull() ?: 0
        }
    }
}
