package com.invisiblewrench.fluttermidicommand

import android.util.Log

internal object MidiLogger {
    private const val tag = "FlutterMIDICommand"
    private const val debugLoggingEnabled = false

    fun debug(message: String) {
        if (debugLoggingEnabled) {
            Log.d(tag, message)
        }
    }
}
