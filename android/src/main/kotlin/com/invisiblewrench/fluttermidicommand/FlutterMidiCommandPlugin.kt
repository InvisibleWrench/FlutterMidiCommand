package com.invisiblewrench.fluttermidicommand

import android.Manifest
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.BluetoothGatt.*
import android.bluetooth.BluetoothProfile.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.media.midi.*
import android.os.*
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterMidiCommandPlugin */
class FlutterMidiCommandPlugin : FlutterPlugin, ActivityAware, MethodCallHandler, PluginRegistry.RequestPermissionsResultListener {

  lateinit var context: Context
  private var activity: Activity? = null
  lateinit var messenger: BinaryMessenger

  private lateinit var midiManager: MidiManager
  private lateinit var handler: Handler

  private var isSupported: Boolean = false

  private var connectedDevices = mutableMapOf<String, Device>()

  lateinit var rxChannel: EventChannel
  lateinit var setupChannel: EventChannel
  lateinit var setupStreamHandler: FMCStreamHandler
  lateinit var bluetoothStateChannel: EventChannel
  lateinit var bluetoothStateHandler: FMCStreamHandler
  lateinit var rxStreamHandler: FMCStreamHandler
  var bluetoothState: String = "unknown"
    set(value) {
      bluetoothStateHandler.send(value)
      field = value
    }

  var bluetoothAdapter: BluetoothAdapter? = null
  var bluetoothScanner: BluetoothLeScanner? = null

  private val PERMISSIONS_REQUEST_ACCESS_LOCATION = 95453 // arbitrary
  var discoveredDevices = mutableSetOf<BluetoothDevice>()
  var ongoingConnections = mutableMapOf<String, Result>()

  var blManager:BluetoothManager? = null

  // #region Lifetime functions
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    messenger = binding.binaryMessenger
    context = binding.applicationContext
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    teardownChannels()
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

  // #endregion

  fun setup() {
    print("setup")

    isSupported =
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_MIDI) &&
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)

    val channel = MethodChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command")
    channel.setMethodCallHandler(this)

    if (!isSupported) {
      return
    }

    handler = Handler(context.mainLooper)
    midiManager = context.getSystemService(Context.MIDI_SERVICE) as MidiManager
    midiManager.registerDeviceCallback(deviceConnectionCallback, handler)

    rxStreamHandler = FMCStreamHandler(handler)
    rxChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/rx_channel")
    rxChannel.setStreamHandler(rxStreamHandler)
    VirtualDeviceService.rxStreamHandler = rxStreamHandler

    setupStreamHandler = FMCStreamHandler(handler)
    setupChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/setup_channel")
    setupChannel.setStreamHandler( setupStreamHandler )

    bluetoothStateHandler = FMCStreamHandler(handler)
    bluetoothStateChannel = EventChannel(messenger, "plugins.invisiblewrench.com/flutter_midi_command/bluetooth_central_state")
    bluetoothStateChannel.setStreamHandler( bluetoothStateHandler )
  }


  override fun onMethodCall(call: MethodCall, result: Result): Unit {
//    Log.d("FlutterMIDICommand","call method ${call.method}")

    if (!isSupported) {
      result.error("ERROR", "MIDI not supported", null)
      return
    }

    when (call.method) {
      "sendData" -> {
        var args : Map<String,Any>? = call.arguments()
        sendData(args?.get("data") as ByteArray, args["timestamp"] as? Long, args["deviceId"]?.toString())
        result.success(null)
      }
      "getDevices" -> {
        result.success(listOfDevices())
      }

      "bluetoothState" -> {
        result.success(bluetoothState)
      }

      "startBluetoothCentral" -> {
        if (blManager != null && bluetoothAdapter != null && bluetoothScanner != null) {
          result.success(null)
        }
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
        var device = (args?.get("device") as Map<String, Any>)
//        var portList = (args["ports"] as List<Map<String, Any>>).map{
//          Port(if (it["id"].toString() is String) it["id"].toString().toInt() else 0 , it["type"].toString())
//        }
        var deviceId = device["id"].toString()
        ongoingConnections[deviceId] = result
        val errorMsg = connectToDevice(deviceId, device["type"].toString())
        if (errorMsg != null) {
          result.error("ERROR", errorMsg, null)
        }
      }
      "disconnectDevice" -> {
        var args = call.arguments<Map<String, Any>>()
        args?.get("id")?.let { disconnectDevice(it.toString()) }
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

      "isNetworkSessionEnabled" -> {
        result.success(false)
      }

      "enableNetworkSession" -> {
        result.success(null)
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

  private fun teardownChannels() {
    // Teardown channels
  }

  fun stopVirtualService() {
    val comp = ComponentName(context, "com.invisiblewrench.fluttermidicommand.VirtualDeviceService")
    val pm = context.packageManager
    pm.setComponentEnabledSetting(comp, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)

  }

  fun appName() : String {
    val pm: PackageManager = context.getPackageManager()
    val info: PackageInfo = pm.getPackageInfo(context.getPackageName(), 0)
    return info.applicationInfo?.loadLabel(pm).toString()
  }

  private fun tryToInitBT() : String? {
    Log.d("FlutterMIDICommand", "tryToInitBT")

    if (Build.VERSION.SDK_INT >= 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED ||
              context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)) {

      bluetoothState = "unknown";

      if (activity != null) {
        val activity = activity!!
//        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_SCAN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_CONNECT)) {
//          Log.d("FlutterMIDICommand", "Show rationale for Bluetooth")
//          bluetoothState = "unauthorized"
//        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT), PERMISSIONS_REQUEST_ACCESS_LOCATION)
//        }
      }

    } else
      if (Build.VERSION.SDK_INT < 31 && (context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED)) {

      bluetoothState = "unknown";

      if (activity != null) {
        var activity = activity!!
//        if (activity.shouldShowRequestPermissionRationale(Manifest.permission.BLUETOOTH_ADMIN) || activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION)) {
//          Log.d("FlutterMIDICommand", "Show rationale for Location")
//          bluetoothState = "unauthorized"
//        } else {
          activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_ADMIN, Manifest.permission.ACCESS_FINE_LOCATION), PERMISSIONS_REQUEST_ACCESS_LOCATION)

//        }
      }
    } else {
      Log.d("FlutterMIDICommand", "Already permitted")

      blManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

      bluetoothAdapter = blManager!!.adapter
      if (bluetoothAdapter != null) {
        bluetoothState = "poweredOn";

        bluetoothScanner = bluetoothAdapter!!.bluetoothLeScanner

        if (bluetoothScanner != null) {
          // Listen for changes in Bluetooth state
          context.registerReceiver(broadcastReceiver, IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED);
            addAction( BluetoothDevice.ACTION_BOND_STATE_CHANGED);
          })

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
      } else

      if (action.equals(BluetoothDevice.ACTION_BOND_STATE_CHANGED)) {
        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
        val previousBondState = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1)
        val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
        val bondTransition = "${previousBondState.toBondStateDescription()} to " + bondState.toBondStateDescription()
        Log.d("Bond state change", "${device?.address} bond state changed | $bondTransition")
        setupStreamHandler.send(bondState.toBondStateDescription())
      }
    }

    private fun Int.toBondStateDescription() = when(this) {
      BluetoothDevice.BOND_BONDED -> "BONDED"
      BluetoothDevice.BOND_BONDING -> "BONDING"
      BluetoothDevice.BOND_NONE -> "NOT BONDED"
      else -> "ERROR: $this"
    }
  }

  private fun startScanningLeDevices() : String? {

    if (bluetoothScanner == null) {
      val errMsg = tryToInitBT()
      errMsg?.let {
        return it
      }
    } else {
      stopScanningLeDevices()
      Log.d("FlutterMIDICommand", "Start BLE Scan")

      bluetoothAdapter?.startDiscovery()

      val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")).build()
      val settings = ScanSettings.Builder().build()
      bluetoothScanner?.startScan(listOf(filter), settings, bleScanner)
    }
    return null
  }

  private fun stopScanningLeDevices() {
    Log.d("FlutterMIDICommand", "Stop BLE Scan")
    bluetoothScanner?.stopScan(bleScanner)
    discoveredDevices.clear()
  }

//fun onRequestPermissionsResult(p0: Int, p1: Array<(out) String!>, p2: IntArray): Boolean
  override fun onRequestPermissionsResult(
          requestCode: Int,
          permissions: Array<out String>,
          grantResults: IntArray): Boolean {
    Log.d("FlutterMIDICommand", "Permissions code: $requestCode grantResults: $grantResults")

    if (!isSupported) {
      Log.d("FlutterMIDICommand", "MIDI not supported")
      return false;
    }

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

  private fun connectToDevice(deviceId:String, type:String) : String? {
    Log.d("FlutterMIDICommand", "connect to $type device: $deviceId")

    if (type == "BLE" || type == "bonded") {
      val bleDevices = discoveredDevices.filter { it.address == deviceId }
      if (bleDevices.isEmpty()) {

        var connectedGattDevice = blManager?.getConnectedDevices(GATT_SERVER)?.filter { it.address == deviceId }?.firstOrNull()
        if (type == "bonded" && connectedGattDevice != null) {
          midiManager.openBluetoothDevice(connectedGattDevice, deviceOpenedListener, handler)
        } else {
          Log.d("FlutterMIDICommand", "Device not found ${deviceId}")
          return "Device not found"
        }
      } else {
        Log.d("FlutterMIDICommand", "Open device")
        midiManager.openBluetoothDevice(bleDevices.first(), deviceOpenedListener, handler)
      }
    } else if (type == "native") {
      val devices =  midiManager.devices.filter { d -> d.id.toString() == deviceId }
      if (devices.isEmpty()) {
        Log.d("FlutterMIDICommand", "not found device $devices")
        return "Device not found"
      } else {
        Log.d("FlutterMIDICommand", "open device ${devices[0]}")
        midiManager.openDevice(devices.first(), deviceOpenedListener, handler)
      }
    } else {
      Log.d("FlutterMIDICommand", "Can't connect to unknown device type $type")
    }
    return null;
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

      var messages = mapOf(
        SCAN_FAILED_ALREADY_STARTED to "Scan already started",
              SCAN_FAILED_APPLICATION_REGISTRATION_FAILED to "Application Registration Failed",
              SCAN_FAILED_FEATURE_UNSUPPORTED to "Future Unsupported",
              SCAN_FAILED_INTERNAL_ERROR to "Internal Error"
//              SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES to "Out of HW Resources",
//              SCAN_FAILED_SCANNING_TOO_FREQUENTLY to "Scanning too frequently"
              )


      Log.d("FlutterMIDICommand", "onScanFailed: $errorCode")
      setupStreamHandler.send("BLE scan failed $errorCode ${messages[errorCode]}")
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
          Log.d("FlutterMIDICommand", "send midi to $it ${it.id}")
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
    var list = mutableMapOf<String, Map<String, Any>>()


    // Bonded BT devices
    var connectedGattDeviceIds = mutableListOf<String>()
    var connectedGattDevices = blManager?.getConnectedDevices(GATT_SERVER)
    connectedGattDevices?.forEach {
      Log.d("FlutterMIDICommand", "connectedGattDevice ${it.address} type ${it.type} name ${it.name}")
      connectedGattDeviceIds.add(it.address)
    }

  var bondedDeviceIds = mutableListOf<String>()
    var bondedDevices = bluetoothAdapter?.getBondedDevices()
    bondedDevices?.forEach {
      Log.d("FlutterMIDICommand", "add bonded device ${it.address} type ${it.type} name ${it.name}")
      bondedDeviceIds.add(it.address)

      var id = it.address
      if (connectedGattDeviceIds.contains(id)) {
        list[id] = mapOf(
          "name" to it.name,
          "id" to id,
          "type" to "bonded",
          "connected" to if (connectedDevices.contains(it.address)) "true" else "false",///*if (connectedGattDeviceIds.contains(id)) "true" else*/ "false",
          "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
          "outputs" to listOf(mapOf("id" to 0, "connected" to false))
        )
      }
    }

    // Discovered BLE devices
    discoveredDevices.forEach {
      var id = it.address;
      Log.d("FlutterMIDICommand", "add discovered device $ type ${it.type}")

      if (list.contains(id)) {
        Log.d("FlutterMIDICommand", "device already in list $id")
      } else {
        Log.d("FlutterMIDICommand", "add native device $id type ${it.type}")
        list[id] = mapOf(
          "name" to it.name,
          "id" to id,
          "type" to "BLE",
          "connected" to if (connectedDevices.contains(id)) "true" else "false",
          "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
          "outputs" to listOf(mapOf("id" to 0, "connected" to false))
        )
      }
    }

    // Generic MIDI devices
    val devs:Array<MidiDeviceInfo> = midiManager.devices
    devs.forEach {
      var id = Device.deviceIdForInfo(it)
      Log.d("FlutterMIDICommand", "add device from midiManager id $id")

      if (list.contains(id)) {
        Log.d("FlutterMIDICommand", "device already in list $id")
      } else {
        Log.d("FlutterMIDICommand", "add native device $id type ${it.type}")

        list[id] = mapOf(
          "name" to (it.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "-"),
          "id" to id,
          "type" to if (bondedDeviceIds.contains(id)) "bonded" else "native",
          "connected" to if (connectedDevices.contains(id)) "true" else "false",
          "inputs" to listOfPorts(it.inputPortCount),
          "outputs" to listOfPorts(it.outputPortCount)
        )
      }
    }

    Log.d("FlutterMIDICommand", "list $list")

    return list.values.toList()
  }


  private val deviceOpenedListener = object : MidiManager.OnDeviceOpenedListener {
    override fun onDeviceOpened(it: MidiDevice?) {
      Log.d("FlutterMIDICommand", "onDeviceOpened")
      it?.also {
        val device = ConnectedDevice(it, this@FlutterMidiCommandPlugin.setupStreamHandler)
        var result = this@FlutterMidiCommandPlugin.ongoingConnections[device.id]
        device.connectWithStreamHandler(rxStreamHandler, result)

        Log.d("FlutterMIDICommand", "Opened device id ${device.id}")
        connectedDevices[device.id] = device
      }
    }
  }

  private val deviceConnectionCallback = object : MidiManager.DeviceCallback() {

    override fun onDeviceAdded(device: MidiDeviceInfo?) {
      super.onDeviceAdded(device)
      device?.also {
        Log.d("FlutterMIDICommand", "MIDI device added $it")
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceFound")
      }
    }

    override fun onDeviceRemoved(device: MidiDeviceInfo?) {
      super.onDeviceRemoved(device)
      device?.also {
        Log.d("FlutterMIDICommand","MIDI device removed $it")
        var id = Device.deviceIdForInfo(it)
        connectedDevices[id]?.also {
          Log.d("FlutterMIDICommand","remove removed device $it")
          connectedDevices.remove(id)
          discoveredDevices.removeIf { discoveredDevice -> discoveredDevice.address == id }
          ongoingConnections.remove(id)
        }
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceLost")
      }
    }

    override fun onDeviceStatusChanged(status: MidiDeviceStatus?) {
      super.onDeviceStatusChanged(status)
      Log.d("FlutterMIDICommand","MIDI device status changed ${status.toString()}")

      status?.also {
        connectedDevices[Device.deviceIdForInfo(it.deviceInfo)]?.also {
          Log.d("FlutterMIDICommand", "update device status $status")
//          it.status = status
        }
      }
      this@FlutterMidiCommandPlugin.setupStreamHandler.send(status.toString())
    }


  }


}


