package com.invisiblewrench.fluttermidicommand

import android.bluetooth.BluetoothDevice

private val deviceServiceUUIDs = mutableMapOf<String, List<String>>()

var BluetoothDevice.serviceUUIDs: List<String>
    get() = deviceServiceUUIDs[address] ?: listOf()
    set(value) {
        deviceServiceUUIDs[address] = value
    }