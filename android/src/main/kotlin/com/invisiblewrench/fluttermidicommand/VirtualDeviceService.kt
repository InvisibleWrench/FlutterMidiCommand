package com.invisiblewrench.fluttermidicommand

import android.content.Intent
import android.media.midi.MidiDeviceService
import android.media.midi.MidiReceiver
import android.util.Log

class VirtualDeviceService() : MidiDeviceService() {
    var receiver:VirtualRXReceiver? = null

    override fun onGetInputPortReceivers(): Array<MidiReceiver> {
        Log.d("FlutterMIDICommand", "Create recevier $this")
        if (receiver == null) {
            receiver = VirtualRXReceiver(FlutterMidiCommandPlugin.rxStreamHandler)
        }
        return  arrayOf(receiver!!)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d("FlutterMIDICommand_vSer", "onStartCommand")

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        receiver = null;
        super.onDestroy()
    }

    class VirtualRXReceiver(stream:FMCStreamHandler) : MidiReceiver() {
        val streamHandler = stream
        val _deviceInfo = mutableMapOf("id" to "FlutterMidiCommand_Virtual", "name" to "FlutterMidiCommand_Virtual", "type" to "native")

        override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
            msg?.also {
                var data = it.slice(IntRange(offset, offset + count - 1))
                streamHandler.send(mapOf("data" to data.toList(), "timestamp" to timestamp, "device" to _deviceInfo))
            }
        }

        override fun send(msg: ByteArray?, offset: Int, count: Int) {
            Log.d("FlutterMIDICommand", "Send override")
            super.send(msg, offset, count)
        }
    }

}