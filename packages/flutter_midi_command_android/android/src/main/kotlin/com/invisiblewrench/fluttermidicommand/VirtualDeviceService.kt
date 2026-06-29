package com.invisiblewrench.fluttermidicommand

import android.content.Intent
import android.media.midi.MidiDeviceService
import android.media.midi.MidiReceiver
import com.invisiblewrench.fluttermidicommand.pigeon.MidiDeviceType
import com.invisiblewrench.fluttermidicommand.pigeon.MidiHostDevice
import com.invisiblewrench.fluttermidicommand.pigeon.MidiPacket

class VirtualDeviceService() : MidiDeviceService() {
    var receiver:VirtualRXReceiver? = null

    override fun onGetInputPortReceivers(): Array<MidiReceiver> {
        MidiLogger.debug("Create receiver $this")
        if (receiver == null) {
            receiver = VirtualRXReceiver(onDataReceived)
        }
        return  arrayOf(receiver!!)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        MidiLogger.debug("onStartCommand")

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        receiver = null;
        super.onDestroy()
    }

    class VirtualRXReceiver(private val onDataReceived: ((MidiPacket) -> Unit)?) : MidiReceiver() {
        private val deviceInfo = MidiHostDevice(
            id = "FlutterMidiCommand_Virtual",
            name = "FlutterMidiCommand_Virtual",
            type = MidiDeviceType.OWN_VIRTUAL,
            connected = true,
            inputs = null,
            outputs = null,
        )

        override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
            msg?.also {
                val data = it.slice(IntRange(offset, offset + count - 1)).toByteArray()
                onDataReceived?.invoke(
                    MidiPacket(
                        device = deviceInfo,
                        data = data,
                        timestamp = timestamp,
                    )
                )
            }
        }

        override fun send(msg: ByteArray?, offset: Int, count: Int) {
            MidiLogger.debug("Send override")
            super.send(msg, offset, count)
        }
    }

    companion

    object {
      var onDataReceived: ((MidiPacket) -> Unit)? = null
    }

}
