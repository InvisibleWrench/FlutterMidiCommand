package com.invisiblewrench.fluttermidicommand

import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.PluginRegistry.Registrar
import android.content.Context.MIDI_SERVICE
import android.media.midi.*
import android.os.Handler
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.FlutterException
import java.util.*
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.Context.BLUETOOTH_SERVICE
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.Manifest
import android.app.Activity.RESULT_CANCELED




class FlutterMidiCommandPlugin(): MethodCallHandler {
  companion object {
    @JvmStatic
    fun registerWith(registrar: Registrar): Unit {
      val channel = MethodChannel(registrar.messenger(), "plugins.invisiblewrench.com/flutter_midi_command")
      var instance = FlutterMidiCommandPlugin()
      channel.setMethodCallHandler(instance)
      instance.setup(registrar)
    }
  }

  lateinit var context:Context
  lateinit var activity:Activity

  lateinit var midiManager:MidiManager
  lateinit var handler: Handler

//  private var device:MidiDevice? = null
  private var connectedDevices = mutableMapOf<String, ConnectedDevice>()

//  private var deviceInputPort:MidiInputPort? = null
//  private var deviceOutputPort:MidiOutputPort? = null

  lateinit var rxChannel:EventChannel
  val rxStreamHandler = FlutterStreamHandler()
  lateinit var setupChannel:EventChannel
  val setupStreamHandler = FlutterStreamHandler()

  lateinit var bluetoothAdapter:BluetoothAdapter
  lateinit var bluetoothScanner:BluetoothLeScanner
  private val PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION = 95453 // arbitrary

  var discoveredDevices = mutableSetOf<BluetoothDevice>()

  lateinit var blManager:BluetoothManager

  fun setup(registrar: Registrar) {
    context = registrar.activeContext()
    activity = registrar.activity()

    rxChannel = EventChannel(registrar.messenger(), "plugins.invisiblewrench.com/flutter_midi_command/rx_channel")
    rxChannel.setStreamHandler( rxStreamHandler )

    setupChannel = EventChannel(registrar.messenger(), "plugins.invisiblewrench.com/flutter_midi_command/setup_channel")
    setupChannel.setStreamHandler( setupStreamHandler )

    handler = Handler(registrar.context().mainLooper)
    midiManager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager
    midiManager.registerDeviceCallback(deviceConnectionCallback, handler)

    blManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    bluetoothAdapter = blManager.adapter
    bluetoothScanner = bluetoothAdapter.bluetoothLeScanner
  }

  override fun onMethodCall(call: MethodCall, result: Result): Unit {
//    Log.d("FlutterMIDICommand","call method ${call.method}")

    if (call.method.equals("scanForDevices")) {
      startScanningLeDevices()
      result.success(null)
    } else if (call.method.equals("stopScanForDevices")) {
      stopScanningLeDevices()
      result.success(null)
    } else if (call.method.equals("getDevices")) {
      result.success(listOfDevices())
    } else if (call.method.equals("connectToDevice")) {
      var args = call.arguments<Map<String, Any>>()
      connectToDevice(args["id"].toString(), args["type"].toString())
      result.success(null)
    } else if (call.method.equals("disconnectDevice")) {
      var args = call.arguments<Map<String, Any>>()
      disconnectDevice(args["id"].toString())
      result.success(null)
    } else if (call.method.equals("sendData")){
      val data = call.arguments<ByteArray>()
      sendData(data, null)
      result.success(null)
    } else {
      result.notImplemented()
    }
  }

  private fun startScanningLeDevices() {

    if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
      activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_COARSE_LOCATION), PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION)
    } else {
      Log.d("FlutterMIDICommand", "Start BLE Scan")
      discoveredDevices.clear()
      val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")).build()
      val settings = ScanSettings.Builder().build()
      bluetoothScanner.startScan(listOf(filter), settings, bleScanner)
    }
  }

  private fun stopScanningLeDevices() {
    bluetoothScanner.stopScan(bleScanner)
    discoveredDevices.clear()
  }

  fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>,
                                 grantResults: IntArray) {
    if (requestCode == PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
      startScanningLeDevices()
    } else {
      Log.d("FlutterMIDICommand", "Perms failed")
    }
  }

  private val bleScanner = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult?) {
      super.onScanResult(callbackType, result)
      Log.d("FlutterMIDICommand","onScanResult: ${result?.device?.address} - ${result?.device?.name}")
      result?.also {
        if (!discoveredDevices.contains(it.device)) {
          discoveredDevices.add(it.device)
          setupStreamHandler.send("deviceFound")
        }
      }
    }

    override fun onScanFailed(errorCode: Int) {
      super.onScanFailed(errorCode)
      Log.d("FlutterMIDICommand", "onScanFailed: $errorCode")
      setupStreamHandler.send("BLE Scan failed $errorCode")
    }
  }

  fun connectToDevice(deviceId:String, type:String) {
    Log.d("FlutterMIDICommand","connect to $type device: $deviceId")

    if (type == "BLE") {
      val bleDevices = discoveredDevices.filter { it.address == deviceId }
      if (bleDevices.count() == 0) {
        Log.d("FlutterMIDICommand", "Device not found ${deviceId}")
      } else {
        Log.d("FlutterMIDICommand", "Stop BLE Scan - Open device")
//        bluetoothScanner.stopScan(bleScanner)
        midiManager.openBluetoothDevice(bleDevices.first(), deviceOpenedListener, handler)
      }
    } else if (type == "native") {
      val devices =  midiManager.devices.filter { d -> d.getId().toString() == deviceId }
      if (devices.count() == 0) {
        Log.d("FlutterMIDICommand", "not found device $devices")
      } else {
        midiManager.openDevice(devices[0], deviceOpenedListener, handler)
      }
    }
  }

  private val deviceOpenedListener = object : MidiManager.OnDeviceOpenedListener {
    override fun onDeviceOpened(it: MidiDevice?) {
      it?.also {
//        device = it
        val id = it.info.id.toString()
        val device = ConnectedDevice(id, it.info.type.toString(), it)
        device.connectWithHandler(RXHandler(rxStreamHandler))
        connectedDevices[id] = device

        Log.d("FlutterMIDICommand", "Opened ${it.info.toString()}")

//        if (it.info.inputPortCount > 0)
//          deviceInputPort = it.openInputPort(0)
//        if (it.info.outputPortCount > 0) {
//          deviceOutputPort = it.openOutputPort(0)
//          deviceOutputPort?.connect()
//        }
//        Log.d("FlutterMIDICommand", "Ports ${deviceInputPort?.portNumber} ${deviceOutputPort?.portNumber}")
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceOpened")
      }
    }
  }

  fun disconnectDevice(deviceId: String) {
    connectedDevices[deviceId]?.also {
      it.close()
      connectedDevices.remove(deviceId)
    }
  }

  fun sendData(data: ByteArray, deviceId: String?) {
    if (deviceId != null && connectedDevices.containsKey(deviceId)) {
      connectedDevices[deviceId]?.let {
        sendDataToDevice(it, data)
      }
    } else {
      connectedDevices.values.forEach {
        sendDataToDevice(it, data)
      }
    }

  }

  fun sendDataToDevice(device:ConnectedDevice, data: ByteArray) {
    device.inputPort?.send(data, 0, data.count())
  }

  fun listOfDevices() : List<Map<String, Any>> {
    var list = mutableListOf<Map<String, Any>>()

    val devs:Array<MidiDeviceInfo> = midiManager.devices
    devs.forEach { d -> list.add(mapOf("name" to d.properties.getString(MidiDeviceInfo.PROPERTY_NAME), "id" to d.id.toString(), "type" to "native", "connected" to if (connectedDevices.contains(d.id.toString())) "true" else "false" )) }

    discoveredDevices.forEach {
      list.add(mapOf("name" to it.name, "id" to it.address, "type" to "BLE", "connected" to if (connectedDevices.contains(it.address)) "true" else "false"))
    }

    return list.toList()
  }

  private val deviceConnectionCallback = object : MidiManager.DeviceCallback() {
    override fun onDeviceAdded(device: MidiDeviceInfo?) {
      super.onDeviceAdded(device)
      device?.also {
          Log.d("FlutterMIDICommand", "device added $it")
      }
    }

    override fun onDeviceRemoved(device: MidiDeviceInfo?) {
      super.onDeviceRemoved(device)
      device?.also {
          Log.d("FlutterMIDICommand","device removed $it")
      }
    }
  }

  class RXHandler(stream: FlutterStreamHandler) : MidiReceiver() {
    val stream = stream
    override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
//      Log.d("FlutterMIDICommand","received data $msg offset:$offset count:$count")
      msg?.also {
        stream.send( it.slice(IntRange(offset, offset+count-1)))
      }
    }
  }

  class FlutterStreamHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null

    // EventChannel.StreamHandler methods
    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
      this.eventSink = eventSink
    }

    override fun onCancel(arguments: Any?) {
      eventSink = null
    }

    fun send(data: Any) {
      eventSink?.success(data)
    }

  }

  class ConnectedDevice {
    var id:String
    var type:String
    var midiDevice:MidiDevice? = null
    var inputPort:MidiInputPort? = null
    var outputPort:MidiOutputPort? = null
    private var handler:MidiReceiver? = null

    constructor(id:String, type:String, device:MidiDevice) {
      this.id = id
      this.type = type
      this.midiDevice = device
    }

    fun connectWithHandler(handler: MidiReceiver) {
      this.inputPort = this.midiDevice?.openInputPort(0)
      this.outputPort = this.midiDevice?.openOutputPort(0)
      this.handler = handler
      this.outputPort?.connect(handler)
    }

    fun close() {
      this.inputPort?.close()
      this.outputPort?.close()
      this.outputPort?.disconnect(this.handler)
      this.handler = null
      this.midiDevice?.close()
    }
  }
}


