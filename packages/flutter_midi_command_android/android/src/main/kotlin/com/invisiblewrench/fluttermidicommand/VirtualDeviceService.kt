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
            receiver = VirtualRXReceiver()
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

    class VirtualRXReceiver() : MidiReceiver() {
        private val deviceInfo = MidiHostDevice(
            id = "FlutterMidiCommand_Virtual",
            name = "FlutterMidiCommand_Virtual",
            type = MidiDeviceType.OWN_VIRTUAL,
            connected = true,
            inputs = null,
            outputs = null,
        )

        // The virtual path used to forward the raw slice, so a device sending running
        // status reached apps unparsed while the hardware path resolved it. Both now go
        // through the same parser.
        private val parser = midiPacketParserFor(deviceInfo) { packet ->
            // Read the callback at send time: the service builds its receiver in
            // onGetInputPortReceivers, which can run before the plugin installs one.
            VirtualDeviceService.onDataReceived?.invoke(packet)
        }

        override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
            msg?.also { parser.parse(it, offset, count, timestamp) }
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
