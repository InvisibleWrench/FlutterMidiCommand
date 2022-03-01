package com.invisiblewrench.fluttermidicommand

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.Registrar

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
import android.content.*

import android.util.Log
import io.flutter.plugin.common.*
import android.content.pm.PackageInfo
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.IBinder
import android.media.midi.MidiDeviceStatus





/** FlutterMidiCommandPlugin */
class FlutterMidiCommandPlugin : FlutterPlugin, ActivityAware, MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

  lateinit var context: Context
  private var activity:Activity? = null
  lateinit var  messenger:BinaryMessenger

  private lateinit var midiManager:MidiManager
  private lateinit var handler: Handler

  private var connectedDevices = mutableMapOf<String, ConnectedDevice>()

  lateinit var rxChannel:EventChannel
//  static var rxStreamHandler:FlutterStreamHandler?
  lateinit var setupChannel:EventChannel
  lateinit var setupStreamHandler:FlutterStreamHandler
  lateinit var bluetoothStateChannel:EventChannel
  lateinit var bluetoothStateHandler:FlutterStreamHandler
  var bluetoothState: String = "unknown"
    set(value) {
      bluetoothStateHandler.send(value);
      field = value
    }


  lateinit var bluetoothAdapter:BluetoothAdapter
  var bluetoothScanner:BluetoothLeScanner? = null
  private val PERMISSIONS_REQUEST_ACCESS_LOCATION = 95453 // arbitrary

  var discoveredDevices = mutableSetOf<BluetoothDevice>()

  var ongoingConnections = mutableMapOf<String, Result>()

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
    activity = p0.activity
    p0.addRequestPermissionsResultListener(this)
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
    p0.addRequestPermissionsResultListener(this)

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
      var instance = FlutterMidiCommandPlugin()
      instance.messenger = registrar.messenger()
      instance.context = registrar.activeContext()
      instance.activity = registrar.activity()
      instance.setup()
    }

    lateinit var rxStreamHandler:FlutterStreamHandler

    fun deviceIdForInfo(info: MidiDeviceInfo): String {
      var isBluetoothDevice = info.type == MidiDeviceInfo.TYPE_BLUETOOTH
      var deviceId: String = if (isBluetoothDevice) info.properties.get(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE).toString() else info.id.toString()
      return deviceId
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

    bluetoothStateHandler = FlutterStreamHandler(handler)
    bluetoothStateChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/bluetooth_central_state")
    bluetoothStateChannel.setStreamHandler( bluetoothStateHandler )
  }


  override fun onMethodCall(call: MethodCall, result: Result): Unit {
//    Log.d("FlutterMIDICommand","call method ${call.method}")

    when (call.method) {
      "sendData" -> {
        var args = call.arguments<Map<String, Any>>()
        sendData(args["data"] as ByteArray, args["timestamp"] as? Long, args["deviceId"]?.toString())
        result.success(null)
      }
      "getDevices" -> {
        result.success(listOfDevices())
      }

      "bluetoothState" -> {
        result.success(bluetoothState)
      }

      "startBluetoothCentral" -> {
        val errorMsg = tryToInitBT()
        if (errorMsg != null) {
          result.error("ERROR", errorMsg, null)
        } else {
          result.success(null)
        }
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
        var device = (args["device"] as Map<String, Any>)
//        var portList = (args["ports"] as List<Map<String, Any>>).map{
//          Port(if (it["id"].toString() is String) it["id"].toString().toInt() else 0 , it["type"].toString())
//        }
        var deviceId = device["id"].toString()
        ongoingConnections[deviceId] = result
        connectToDevice(deviceId, device["type"].toString())
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

      "addVirtualDevice" -> {
        startVirtualService()
      }

      "removeVirtualDevice" -> {
        stopVirtualService()
      }

      else -> {
        result.notImplemented()
      }
    }
  }

  fun startVirtualService() {
    val comp = ComponentName(context, "com.invisiblewrench.fluttermidicommand.VirtualDeviceService")
    val pm = context.packageManager
    pm.setComponentEnabledSetting(comp, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.SYNCHRONOUS or PackageManager.DONT_KILL_APP)

  }

  fun stopVirtualService() {
    val comp = ComponentName(context, "com.invisiblewrench.fluttermidicommand.VirtualDeviceService")
    val pm = context.packageManager
    pm.setComponentEnabledSetting(comp, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)

  }

  fun appName() : String {
    val pm: PackageManager = context.getPackageManager()
    val info: PackageInfo = pm.getPackageInfo(context.getPackageName(), 0)
    return info.applicationInfo.loadLabel(pm).toString()
  }

  private fun tryToInitBT() : String? {
    Log.d("FlutterMIDICommand", "tryToInitBT")

    if (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {

      bluetoothState = "unknown";

      if (activity != null) {
        var activity = activity!!
        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_ADMIN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)) {
          Log.d("FlutterMIDICommand", "Show rationale for Location")
          bluetoothState = "unauthorized"
        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_FINE_LOCATION), PERMISSIONS_REQUEST_ACCESS_LOCATION)

        }
      }
    } else {
      Log.d("FlutterMIDICommand", "Already permitted")

      blManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

      bluetoothAdapter = blManager.adapter
      if (bluetoothAdapter != null) {
        bluetoothState = "poweredOn";

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
        bluetoothState = "unsupported";
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
            bluetoothState = "poweredOff";
            bluetoothScanner = null
          }

          BluetoothAdapter.STATE_TURNING_OFF -> {
            Log.d("FlutterMIDICommand", "BT is now turning off")
          }

          BluetoothAdapter.STATE_ON -> {
            bluetoothState = "poweredOn";
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


  override fun onRequestPermissionsResult(
          requestCode: Int,
          permissions: Array<out String>?,
          grantResults: IntArray?): Boolean {
    Log.d("FlutterMIDICommand", "Permissions code: $requestCode grantResults: $grantResults")


    if (requestCode == PERMISSIONS_REQUEST_ACCESS_LOCATION && grantResults?.get(0) == PackageManager.PERMISSION_GRANTED) {
      startScanningLeDevices()
      return true;
    } else {
      bluetoothState = "unauthorized"
      Log.d("FlutterMIDICommand", "Perms failed")
      return true;
    }

    return false;
  }

  private fun connectToDevice(deviceId:String, type:String) {
    Log.d("FlutterMIDICommand", "connect to $type device: $deviceId")

    if (type == "BLE") {
      val bleDevices = discoveredDevices.filter { it.address == deviceId }
      if (bleDevices.count() == 0) {
        Log.d("FlutterMIDICommand", "Device not found ${deviceId}")
      } else {
        Log.d("FlutterMIDICommand", "Open device")
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
          setupStreamHandler.send("deviceAppeared")
        }
      }
    }

    override fun onScanFailed(errorCode: Int) {
      super.onScanFailed(errorCode)
      Log.d("FlutterMIDICommand", "onScanFailed: $errorCode")
      setupStreamHandler.send("BLE scan failed $errorCode")
    }
  }


  fun teardown() {
    Log.d("FlutterMIDICommand", "teardown")

    stopVirtualService()

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
        val device = ConnectedDevice(it, this@FlutterMidiCommandPlugin.setupStreamHandler)
        var result = this@FlutterMidiCommandPlugin.ongoingConnections[device.id]
        device.connectWithReceiver(RXReceiver(rxStreamHandler, it), result)
        Log.d("FlutterMIDICommand", "Opened device id ${device.id}")
        connectedDevices[device.id] = device
      }
    }
  }

  fun disconnectDevice(deviceId: String) {
    connectedDevices[deviceId]?.also {
      it.close()
      connectedDevices.remove(deviceId)
    }
  }

  fun sendData(data: ByteArray, timestamp: Long?, deviceId: String?) {
    if (deviceId != null) {
      if (connectedDevices.containsKey(deviceId)) {
        connectedDevices[deviceId]?.let {
//          Log.d("FlutterMIDICommand", "send midi to $it ${it.id}")
          it.send(data, timestamp)
        }
      } else {
        Log.d("FlutterMIDICommand", "no device for id $deviceId")
      }
    }
     else {
      connectedDevices.values.forEach {
        it.send(data, timestamp)
      }
    }
  }

  fun listOfPorts(count: Int) :  List<Map<String, Any>> {
    return (0 until count).map { mapOf("id" to it, "connected" to false) }
  }

  fun listOfDevices() : List<Map<String, Any>> {
    var list = mutableListOf<Map<String, Any>>()

    val devs:Array<MidiDeviceInfo> = midiManager.devices
    Log.d("FlutterMIDICommand", "devices $devs")

    var connectedBleDeviceIds = mutableListOf<String>()

    devs.forEach {
//      Log.d("FlutterMIDICommand", "dev type ${it.type}")
      var isBluetooth = it.type == MidiDeviceInfo.TYPE_BLUETOOTH
      if (isBluetooth) {
        connectedBleDeviceIds.add(it.properties.get(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE).toString())
      }

      var id = deviceIdForInfo(it)

      list.add(mapOf(
            "name" to (it.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "-"),
            "id" to id,
            "type" to if (isBluetooth) "BLE" else "native",
            "connected" to if (connectedDevices.contains(id)) "true" else "false",
            "inputs" to listOfPorts(it.inputPortCount),
            "outputs" to listOfPorts(it.outputPortCount)
          )
    )}

    discoveredDevices.forEach {
      if (!connectedBleDeviceIds.contains(it.address)) {
        list.add(mapOf(
                "name" to it.name,
                "id" to it.address,
                "type" to "BLE",
                "connected" to if (connectedDevices.contains(it.address)) "true" else "false",
                "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
                "outputs" to listOf(mapOf("id" to 0, "connected" to false))
        ))
      }
    }

    Log.d("FlutterMIDICommand", "list $list")

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
        var id = deviceIdForInfo(it)
        connectedDevices[id]?.also {
          Log.d("FlutterMIDICommand","remove removed device $it")
          connectedDevices.remove(id)
        }
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceLost")
      }
    }

    override fun onDeviceStatusChanged(status: MidiDeviceStatus?) {
      super.onDeviceStatusChanged(status)
      Log.d("FlutterMIDICommand","device status changed ${status.toString()}")

      status?.also {
        connectedDevices[deviceIdForInfo(it.deviceInfo)]?.also {
          Log.d("FlutterMIDICommand", "update device status $status")
          it.status = status
        }
      }
      this@FlutterMidiCommandPlugin.setupStreamHandler.send(status.toString())
    }


  }

  class RXReceiver(stream: FlutterStreamHandler, device: MidiDevice) : MidiReceiver() {
    val stream = stream
    var isBluetoothDevice = device.info.type == MidiDeviceInfo.TYPE_BLUETOOTH
    val deviceInfo = mapOf("id" to if(isBluetoothDevice) device.info.properties.get(MidiDeviceInfo.PROPERTY_BLUETOOTH_DEVICE).toString() else device.info.id.toString(), "name" to device.info.properties.getString(MidiDeviceInfo.PROPERTY_NAME), "type" to if(isBluetoothDevice) "BLE" else "native")

    // MIDI parsing
    enum class PARSER_STATE
    {
      HEADER,
      PARAMS,
      SYSEX,
    }

    var parserState = PARSER_STATE.HEADER

    var sysExBuffer = mutableListOf<Byte>()
    var midiBuffer = mutableListOf<Byte>()
    var midiPacketLength:Int = 0
    var statusByte:Byte = 0

    override fun onSend(msg: ByteArray?, offset: Int, count: Int, timestamp: Long) {
      msg?.also {
        var data = it.slice(IntRange(offset, offset + count - 1))
//        Log.d("FlutterMIDICommand", "data sliced $data offset $offset count $count")

        if (data.size > 0) {
          for (i in 0 until data.size) {
            var midiByte: Byte = data[i]
            var midiInt = midiByte.toInt() and 0xFF

//          Log.d("FlutterMIDICommand", "parserState $parserState byte $midiByte")

            when (parserState) {
              PARSER_STATE.HEADER -> {
                if (midiInt == 0xF0) {
                  parserState = PARSER_STATE.SYSEX
                  sysExBuffer.clear()
                  sysExBuffer.add(midiByte)
                } else if (midiInt and 0x80 == 0x80) {
                  // some kind of midi msg
                  statusByte = midiByte
                  midiPacketLength = lengthOfMessageType(midiInt)
//                Log.d("FlutterMIDICommand", "expected length $midiPacketLength")
                  midiBuffer.clear()
                  midiBuffer.add(midiByte)
                  parserState = PARSER_STATE.PARAMS
                } else {
                  // in header state but no status byte, do running status
                  midiBuffer.clear()
                  midiBuffer.add(statusByte)
                  midiBuffer.add(midiByte)
                  parserState = PARSER_STATE.PARAMS
                  finalizeMessageIfComplete(timestamp)
                }
              }

              PARSER_STATE.SYSEX -> {
                if (midiInt == 0xF0) {
                  // Android can skip SysEx end bytes, when more sysex messages are coming in succession.
                  // in an attempt to save the situation, add an end byte to the current buffer and start a new one.
                  sysExBuffer.add(0xF7.toByte())
//                Log.d("FlutterMIDICommand", "sysex force finalized $sysExBuffer")
                  stream.send(
                    mapOf(
                      "data" to sysExBuffer.toList(),
                      "timestamp" to timestamp,
                      "device" to deviceInfo
                    )
                  )
                  sysExBuffer.clear();
                }
                sysExBuffer.add(midiByte)
                if (midiInt == 0xF7) {
                  // Sysex complete
//                Log.d("FlutterMIDICommand", "sysex complete $sysExBuffer")
                  stream.send(
                    mapOf(
                      "data" to sysExBuffer.toList(),
                      "timestamp" to timestamp,
                      "device" to deviceInfo
                    )
                  )
                  parserState = PARSER_STATE.HEADER
                }
              }

              PARSER_STATE.PARAMS -> {
                midiBuffer.add(midiByte)
                finalizeMessageIfComplete(timestamp)
              }
            }
          }
        }
      }
    }

    fun finalizeMessageIfComplete(timestamp: Long) {
      if (midiBuffer.size == midiPacketLength) {
//        Log.d("FlutterMIDICommand", "status complete $midiBuffer")
        stream.send( mapOf("data" to midiBuffer.toList(), "timestamp" to timestamp, "device" to deviceInfo))
        parserState = PARSER_STATE.HEADER
      }
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
      handler.post {
        eventSink?.success(data)
      }
    }
  }

  class Port {
    var id:Int
    var type:String

    constructor(id:Int, type:String) {
      this.id = id
      this.type = type
    }
  }

  class ConnectedDevice {
    var id:String
    var type:String
    lateinit var midiDevice:MidiDevice
    var inputPort:MidiInputPort? = null
    var outputPort:MidiOutputPort? = null
    var status:MidiDeviceStatus? = null
    private var receiver:MidiReceiver? = null
    private var streamHandler:FlutterStreamHandler? = null
    private var isOwnVirtualDevice = false;

    constructor(device:MidiDevice, streamHandler:FlutterStreamHandler) {
      this.midiDevice = device
      this.streamHandler = streamHandler
      this.id = deviceIdForInfo(device.info)
      this.type = device.info.type.toString()
    }

    fun connectWithReceiver(receiver: MidiReceiver, connectResult:Result?) {
      Log.d("FlutterMIDICommand","connectWithHandler")

      this.midiDevice.info?.let {

        Log.d("FlutterMIDICommand","inputPorts ${it.inputPortCount} outputPorts ${it.outputPortCount}")
//
//        it.ports.forEach {
//          Log.d("FlutterMIDICommand", "${it.name} ${it.type} ${it.portNumber}")
//        }

//        Log.d("FlutterMIDICommand", "is binder alive? ${this.midiDevice?.info?.properties?.getBinder(null)?.isBinderAlive}")

        var serviceInfo = it.properties.getParcelable<ServiceInfo>("service_info")
        if (serviceInfo?.name == "com.invisiblewrench.fluttermidicommand.VirtualDeviceService") {
          Log.d("FlutterMIDICommand", "Own virtual")
          isOwnVirtualDevice = true
        } else {
          if (it.inputPortCount > 0) {
            Log.d("FlutterMIDICommand", "Open input port")
            this.inputPort = this.midiDevice.openInputPort(0)
          }
        }
        if (it.outputPortCount > 0) {
          Log.d("FlutterMIDICommand", "Open output port")
          this.outputPort = this.midiDevice.openOutputPort(0)
          this.outputPort?.connect(receiver)
        }
          }

      this.receiver = receiver


      Handler().postDelayed({
        connectResult?.success(null)
        streamHandler?.send("deviceConnected")
      }, 2500)
    }

//    fun openPorts(ports: List<Port>) {
//      this.midiDevice.info?.let { deviceInfo ->
//        Log.d("FlutterMIDICommand","inputPorts ${deviceInfo.inputPortCount} outputPorts ${deviceInfo.outputPortCount}")
//
//        ports.forEach { port ->
//          Log.d("FlutterMIDICommand", "Open port ${port.type} ${port.id}")
//          when (port.type) {
//            "MidiPortType.IN" -> {
//              if (deviceInfo.inputPortCount > port.id) {
//                Log.d("FlutterMIDICommand", "Open input port ${port.id}")
//                this.inputPort = this.midiDevice.openInputPort(port.id)
//              }
//            }
//            "MidiPortType.OUT" -> {
//              if (deviceInfo.outputPortCount > port.id) {
//                Log.d("FlutterMIDICommand", "Open output port ${port.id}")
//                this.outputPort = this.midiDevice.openOutputPort(port.id)
//                this.outputPort?.connect(receiver)
//              }
//            }
//            else -> {
//              Log.d("FlutterMIDICommand", "Unknown MIDI port type ${port.type}. Not opening.")
//            }
//          }
//        }
//      }
//    }

    fun send(data: ByteArray, timestamp: Long?) {

      if(isOwnVirtualDevice) {
        Log.d("FlutterMIDICommand", "Send to recevier")
        if (timestamp == null)
          this.receiver?.send(data, 0, data.size)
        else
          this.receiver?.send(data, 0, data.size, timestamp)

      } else {
        Log.d("FlutterMIDICommand", "Send to input port ${this.inputPort}")
        this.inputPort?.send(data, 0, data.count(), if (timestamp is Long) timestamp else 0)
      }
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
      this.midiDevice.close()

      streamHandler?.send("deviceDisconnected")
    }

  }

}
  class VirtualRXReceiver(stream:FlutterMidiCommandPlugin.FlutterStreamHandler) : MidiReceiver() {
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
  }
