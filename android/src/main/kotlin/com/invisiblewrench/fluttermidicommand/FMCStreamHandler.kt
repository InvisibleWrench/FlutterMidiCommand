package com.invisiblewrench.fluttermidicommand

import android.os.Handler
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

class FMCStreamHandler(handler: Handler) : EventChannel.StreamHandler {
    val handler = handler
    private var eventSink: EventChannel.EventSink? = null

    // EventChannel.StreamHandler methods
    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        Log.d("FlutterMIDICommand","FlutterStreamHandler onListen")
        this.eventSink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        Log.d("FlutterMIDICommand","FlutterStreamHandler onCancel")
        eventSink = null
    }

    fun send(data: Any) {
        handler.post {
            eventSink?.success(data)
        }
    }
}