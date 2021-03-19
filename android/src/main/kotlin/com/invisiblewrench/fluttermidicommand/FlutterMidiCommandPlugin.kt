package com.invisiblewrench.fluttermidicommand

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.Registrar
import io.flutter.plugin.common.EventChannel

import android.app.Activity
import android.os.Handler
import android.media.midi.*
import android.content.Context.MIDI_SERVICE
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.*
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.flutter.plugin.common.BinaryMessenger

import android.util.Log


/** FlutterMidiCommandPlugin */
public class FlutterMidiCommandPlugin : FlutterPlugin, ActivityAware, MethodCallHandler {

  lateinit var context: Context
  private var activity:Activity? = null
  lateinit var  messenger:BinaryMessenger

  private lateinit var midiManager:MidiManager
  private lateinit var handler: Handler

  private var connectedDevices = mutableMapOf<String, ConnectedDevice>()

  lateinit var rxChannel:EventChannel
  lateinit var rxStreamHandler:FlutterStreamHandler
  lateinit var setupChannel:EventChannel
  lateinit var setupStreamHandler:FlutterStreamHandler

  lateinit var bluetoothAdapter:BluetoothAdapter
  var bluetoothScanner:BluetoothLeScanner? = null
  private val PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION = 95453 // arbitrary

  var discoveredDevices = mutableSetOf<BluetoothDevice>()

  lateinit var blManager:BluetoothManager

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    messenger = flutterPluginBinding.binaryMessenger
    context = flutterPluginBinding.applicationContext
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    print("detached from engine")
  }

  override fun onAttachedToActivity(p0: ActivityPluginBinding) {
    print("onAttachedToActivity")
    // TODO: your plugin is now attached to an Activity
    activity = p0?.activity
    setup()
  }

  override fun onDetachedFromActivityForConfigChanges() {
    print("onDetachedFromActivityForConfigChanges")
    // TODO: the Activity your plugin was attached to was
// destroyed to change configuration.
// This call will be followed by onReattachedToActivityForConfigChanges().
  }

  override fun onReattachedToActivityForConfigChanges(p0: ActivityPluginBinding) {
    // TODO: your plugin is now attached to a new Activity

// after a configuration change.
    print("onReattachedToActivityForConfigChanges")
  }

  override fun onDetachedFromActivity() { // TODO: your plugin is no longer associated with an Activity.
// Clean up references.
    print("onDetachedFromActivity")
    activity = null
  }


  // This static function is optional and equivalent to onAttachedToEngine. It supports the old
  // pre-Flutter-1.12 Android projects. You are encouraged to continue supporting
  // plugin registration via this function while apps migrate to use the new Android APIs
  // post-flutter-1.12 via https://flutter.dev/go/android-project-migration.
  //
  // It is encouraged to share logic between onAttachedToEngine and registerWith to keep
  // them functionally equivalent. Only one of onAttachedToEngine or registerWith will be called
  // depending on the user's project. onAttachedToEngine or registerWith must both be defined
  // in the same class.
  companion object {
    @JvmStatic
    fun registerWith(registrar: Registrar) {
//      val channel = MethodChannel(registrar.messenger(), "fluttermidicommand")
      var instance = FlutterMidiCommandPlugin()
      instance.messenger = registrar.messenger()
      instance.context = registrar.activeContext()
      instance.activity = registrar.activity()
      instance.setup()
    }
  }


  fun setup() {
    print("setup")
    val channel = MethodChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command")
    channel.setMethodCallHandler(this)

    handler = Handler(context.mainLooper)
    midiManager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager
    midiManager.registerDeviceCallback(deviceConnectionCallback, handler)

    rxStreamHandler = FlutterStreamHandler(handler)
    rxChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/rx_channel")
    rxChannel.setStreamHandler( rxStreamHandler )

    setupStreamHandler = FlutterStreamHandler(handler)
    setupChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/setup_channel")
    setupChannel.setStreamHandler( setupStreamHandler )
  }


  override fun onMethodCall(call: MethodCall, result: Result): Unit {
//    Log.d("FlutterMIDICommand","call method ${call.method}")

    when (call.method) {
      "sendData" -> {
        val data = call.arguments<ByteArray>()
        sendData(data, null)
        result.success(null)
      }
      "getDevices" -> {
        result.success(listOfDevices())
      }
      "scanForDevices" -> {
        val errorMsg = startScanningLeDevices()
        if (errorMsg != null) {
          result.error("ERROR", errorMsg, null)
        } else {
          result.success(null)
        }
      }
      "stopScanForDevices" -> {
        stopScanningLeDevices()
        result.success(null)
      }
      "connectToDevice" -> {
        var args = call.arguments<Map<String, Any>>()
        connectToDevice(args["id"].toString(), args["type"].toString())
        result.success(null)
      }
      "disconnectDevice" -> {
        var args = call.arguments<Map<String, Any>>()
        disconnectDevice(args["id"].toString())
        result.success(null)
      }
      "teardown" -> {
        teardown()
        result.success(null)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun tryToInitBT() : String? {
    Log.d("FlutterMIDICommand", "tryToInitBT")

    if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {

      if (activity != null) {
        var activity = activity!!
        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_ADMIN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION)) {
          Log.d("FlutterMIDICommand", "Show rationale for Location")
          return "showRationaleForPermission"
        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_COARSE_LOCATION), PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION)
        }
      }
    } else {
      Log.d("FlutterMIDICommand", "Already permitted")

      blManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
      bluetoothAdapter = blManager.adapter
      if (bluetoothAdapter != null) {
        bluetoothScanner = bluetoothAdapter.bluetoothLeScanner

        if (bluetoothScanner != null) {
          // Listen for changes in Bluetooth state
          context.registerReceiver(broadcastReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))

          startScanningLeDevices()
        } else {
          Log.d("FlutterMIDICommand", "bluetoothScanner is null")
          return "bluetoothNotAvailable"
        }
      } else {
        Log.d("FlutterMIDICommand", "bluetoothAdapter is null")
      }
    }
    return null
  }

  private val broadcastReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      val action = intent.action

      if (action.equals(BluetoothAdapter.ACTION_STATE_CHANGED)) {
        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

        when (state) {
          BluetoothAdapter.STATE_OFF -> {
            Log.d("FlutterMIDICommand", "BT is now off")
            bluetoothScanner = null
          }

          BluetoothAdapter.STATE_TURNING_OFF -> {
            Log.d("FlutterMIDICommand", "BT is now turning off")
          }

          BluetoothAdapter.STATE_ON -> {
            Log.d("FlutterMIDICommand", "BT is now on")
          }
        }
      }
    }
  }


  private fun startScanningLeDevices() : String? {

    if (bluetoothScanner == null) {
      val errMsg = tryToInitBT()
      errMsg?.let {
        return it
      }
    } else {
      Log.d("FlutterMIDICommand", "Start BLE Scan")
      discoveredDevices.clear()
      val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")).build()
      val settings = ScanSettings.Builder().build()
      bluetoothScanner?.startScan(listOf(filter), settings, bleScanner)
    }
    return null
  }

  private fun stopScanningLeDevices() {
    bluetoothScanner?.stopScan(bleScanner)
    discoveredDevices.clear()
  }

  fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>,
                                 grantResults: IntArray) {
    Log.d("FlutterMIDICommand", "Permissions code: $requestCode grantResults: $grantResults")
    if (requestCode == PERMISSIONS_REQUEST_ACCESS_COARSE_LOCATION && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
      startScanningLeDevices()
    } else {
      Log.d("FlutterMIDICommand", "Perms failed")
    }
  }

  private fun connectToDevice(deviceId:String, type:String) {
    Log.d("FlutterMIDICommand", "connect to $type device: $deviceId")


    if (type == "BLE") {
      val bleDevices = discoveredDevices.filter { it.address == deviceId }
      if (bleDevices.count() == 0) {
        Log.d("FlutterMIDICommand", "Device not found ${deviceId}")
      } else {
        Log.d("FlutterMIDICommand", "Stop BLE Scan - Open device")
        midiManager.openBluetoothDevice(bleDevices.first(), deviceOpenedListener, handler)
      }
    } else if (type == "native") {
      val devices =  midiManager.devices.filter { d -> d.id.toString() == deviceId }
      if (devices.count() == 0) {
        Log.d("FlutterMIDICommand", "not found device $devices")
      } else {
        Log.d("FlutterMIDICommand", "open device ${devices[0]}")
        midiManager.openDevice(devices[0], deviceOpenedListener, handler)
      }
    }
  }

  private val bleScanner = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult?) {
      super.onScanResult(callbackType, result)
      Log.d("FlutterMIDICommand", "onScanResult: ${result?.device?.address} - ${result?.device?.name}")
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


  fun teardown() {
    Log.d("FlutterMIDICommand", "teardown")

    connectedDevices.forEach { s, connectedDevice -> connectedDevice.close() }
    connectedDevices.clear()

    Log.d("FlutterMIDICommand", "unregisterDeviceCallback")
    midiManager.unregisterDeviceCallback(deviceConnectionCallback)
    Log.d("FlutterMIDICommand", "unregister broadcastReceiver")
    try {
      context.unregisterReceiver(broadcastReceiver)
    } catch (e: Exception) {
      // The receiver was not registered.
      // There is nothing to do in that case.
      // Everything is fine.
    }
  }


  private val deviceOpenedListener = object : MidiManager.OnDeviceOpenedListener {
    override fun onDeviceOpened(it: MidiDevice?) {
      Log.d("FlutterMIDICommand", "onDeviceOpened")
      it?.also {

        val id = it.info.id.toString()
        Log.d("FlutterMIDICommand", "Opened\n${it.info.toString()}")

        val device = ConnectedDevice(it)
        device.connectWithReceiver(RXReceiver(rxStreamHandler))
        connectedDevices[id] = device


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
        it.send(data)
      }
    } else {
      connectedDevices.values.forEach {
        it.send(data)
      }
    }
  }


  fun listOfDevices() : List<Map<String, Any>> {
    var list = mutableListOf<Map<String, Any>>()

    val devs:Array<MidiDeviceInfo> = midiManager.devices
    Log.d("FlutterMIDICommand", "devices $devs")
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
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceFound")
      }
    }

    override fun onDeviceRemoved(device: MidiDeviceInfo?) {
      super.onDeviceRemoved(device)
      device?.also {
        Log.d("FlutterMIDICommand","device removed $it")
        connectedDevices[it.id.toString()]?.also {
          Log.d("FlutterMIDICommand","remove removed device $it")
          connectedDevices.remove(it.id)
        }
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceLost")
      }
    }

    override fun onDeviceStatusChanged(status: MidiDeviceStatus?) {
      super.onDeviceStatusChanged(status)
      Log.d("FlutterMIDICommand","device status changed ${status.toString()}")

      status?.also {
        connectedDevices[status.deviceInfo.id.toString()]?.also {
          Log.d("FlutterMIDICommand", "update device status")
          it.status = status
        }
      }

      this@FlutterMidiCommandPlugin.setupStreamHandler.send("onDeviceStatusChanged")

    }
  }

  class RXReceiver(stream: FlutterStreamHandler) : MidiReceiver() {
    val stream = stream
    override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
//      Log.d("FlutterMIDICommand","RXReceiver onSend(receive) ${this}")
      msg?.also {
        stream.send( it.slice(IntRange(offset, offset+count-1)))
      }
    }
  }

  class FlutterStreamHandler(handler: Handler) : EventChannel.StreamHandler {
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
//      Log.d("FlutterMIDICommand","FlutterStreamHandler send ${data}")
      handler.post {
        eventSink?.success(data)
      }
    }
  }

  class ConnectedDevice {
    var id:String
    var type:String
    var midiDevice:MidiDevice? = null
    var inputPort:MidiInputPort? = null
    var outputPort:MidiOutputPort? = null
    var status:MidiDeviceStatus? = null
    private var receiver:MidiReceiver? = null

    constructor(device:MidiDevice) {
      this.midiDevice = device
      this.id = device.info.id.toString()
      this.type = device.info.type.toString()
    }

    fun connectWithReceiver(receiver: MidiReceiver) {
      Log.d("FlutterMIDICommand","connectWithHandler")

      this.midiDevice?.info?.let {
//        Log.d("FlutterMIDICommand","inputPorts ${it.inputPortCount} outputPorts ${it.outputPortCount}")

//        it.ports.forEach {
//          Log.d("FlutterMIDICommand", "${it.name} ${it.type} ${it.portNumber}")
//        }

//        Log.d("FlutterMIDICommand", "is binder alive? ${this.midiDevice?.info?.properties?.getBinder(null)?.isBinderAlive}")

        if(it.inputPortCount > 0) {
          Log.d("FlutterMIDICommand", "Open input port")
          this.inputPort = this.midiDevice?.openInputPort(0)
        }
        if (it.outputPortCount > 0) {
          Log.d("FlutterMIDICommand", "Open output port")
          this.outputPort = this.midiDevice?.openOutputPort(0)
        }
      }

      this.receiver = receiver
      this.outputPort?.connect(receiver)
    }

    fun send(data: ByteArray) {
      this.inputPort?.send(data, 0, data.count())
    }

    fun close() {
      Log.d("FlutterMIDICommand", "Flush input port ${this.inputPort}")
      this.inputPort?.flush()
      Log.d("FlutterMIDICommand", "Close input port ${this.inputPort}")
      this.inputPort?.close()
      Log.d("FlutterMIDICommand", "Close output port ${this.outputPort}")
      this.outputPort?.close()
      Log.d("FlutterMIDICommand", "Disconnect receiver ${this.receiver}")
      this.outputPort?.disconnect(this.receiver)
      this.receiver = null
      Log.d("FlutterMIDICommand", "Close device ${this.midiDevice}")
      this.midiDevice?.close()
    }

  }
}
