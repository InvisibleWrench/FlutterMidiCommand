package com.invisiblewrench.fluttermidicommand

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.bluetooth.*
import android.bluetooth.BluetoothGatt.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.LocationManager
import android.media.midi.*
import android.os.*
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import com.welie.blessed.BluetoothCentralManager
import com.welie.blessed.BluetoothCentralManagerCallback
import com.welie.blessed.BluetoothPeripheral
import com.welie.blessed.HciStatus
import com.welie.blessed.ScanFailure
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.UUID
import java.util.Objects

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
  var central: BluetoothCentralManager? = null
  private val HW_ENABLE_BLUETOOTH = 95452 // arbitrary
  private val PERMISSIONS_REQUEST_ACCESS_LOCATION = 95453 // arbitrary
var discoveredDevices = mutableMapOf<String, Map<String, Any>>()
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
    Log.d(TAG, "onAttachedToActivity")
    // TODO: your plugin is now attached to an Activity
    activity = p0.activity
    p0.addRequestPermissionsResultListener(this)
    setup()
  }

  override fun onDetachedFromActivityForConfigChanges() {
    Log.d(TAG, "onDetachedFromActivityForConfigChanges")
    // TODO: the Activity your plugin was attached to was
// destroyed to change configuration.
// This call will be followed by onReattachedToActivityForConfigChanges().
  }

  override fun onReattachedToActivityForConfigChanges(p0: ActivityPluginBinding) {
    // TODO: your plugin is now attached to a new Activity
    p0.addRequestPermissionsResultListener(this)

// after a configuration change.
    Log.d(TAG, "onReattachedToActivityForConfigChanges")
  }

  override fun onDetachedFromActivity() { // TODO: your plugin is no longer associated with an Activity.
// Clean up references.
    Log.d(TAG, "onDetachedFromActivity")
    activity = null
    central?.close()
  }

  // #endregion

  companion object {
    var serviceUUID = UUID.fromString("03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    var characteristicUUID = UUID.fromString("7772E5DB-3868-4112-A1A9-F2669D106BF3")
    private const val TAG = "FlutterMidiCommand"
  }

  fun setup() {
    Log.d(TAG, "setup")

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
//    Log.d(TAG, "FlutterMIDICommand","call method ${call.method}")

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
        if (bluetoothAdapter == null && bluetoothState != "poweredOff") {
          result.success(bluetoothState)
        } else {
          if (bluetoothAdapter!!.state == BluetoothAdapter.STATE_ON) {
            result.success("poweredOn")
          } else {
            result.success("poweredOff")
          }
        }
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
        val errorMsg = startScan()
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
        if (ongoingConnections.containsKey(deviceId)) {
          result.error("ERROR", "Already connecting to device", deviceId)
        }
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
    Log.d(TAG, "tryToInitBT")

    if (blManager != null && bluetoothAdapter != null) {
      Log.d(TAG, "Bluetooth already up")
      return null
    }

    if (getBluetoothManager().getAdapter() != null) {
      Log.d(TAG, "Adapter is there - register for state changes")
      context.registerReceiver(broadcastReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))

      if (!isBluetoothEnabled()) {
        Log.d(TAG, "Bluetooth is not enabled - ask")
        val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
        activity?.startActivityForResult(
          enableBtIntent,
          HW_ENABLE_BLUETOOTH
        )
      } else {
        Log.d(TAG, "Check permissions")
        bluetoothState = "poweredOn"
      }
      return null
    } else {
      Log.d(TAG, "This device has no Bluetooth hardware")
      bluetoothState = "unsupported";
      return "noBluetoothHardware"
    }
  }

  private val broadcastReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      val action = intent.action

      if (action.equals(BluetoothAdapter.ACTION_STATE_CHANGED)) {
        val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)

        Log.d(TAG, "BT connection state changed $state")

        when (state) {
          BluetoothAdapter.STATE_OFF -> {
            Log.d(TAG, "BT is now off")
            bluetoothState = "poweredOff";
          }

          BluetoothAdapter.STATE_TURNING_OFF -> {
            Log.d(TAG, "BT is now turning off")
          }

          BluetoothAdapter.STATE_ON -> {
            bluetoothState = "poweredOn";
            Log.d(TAG, "BT is now on")
          }
        }
      }
    }
  }

  private fun startScan() : String? {
    Log.d(TAG, "Start BLE Scan")

    checkPermissions()

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S){
      if (!areLocationServicesEnabled()) {
        Log.d(TAG, "Location services are required")
        return "Location services are required"
      }
    }

    discoveredDevices.clear()

     central?.startPairingPopupHack()
     handler.postDelayed({
      // Scan for peripherals with a certain service UUIDs
      central?.scanForPeripheralsWithServices(
        setOf(serviceUUID)
      )
    }, 1100)
    return null
  }

  private fun stopScanningLeDevices() {
    Log.d(TAG, "Stop BLE Scan")
    central?.stopScan()
  }


  private fun connectToDevice(deviceId:String, type:String) : String? {
    Log.d(TAG, "connect to $type device: $deviceId")

    if (type == "BLE") {
      // Connect using BLESSED
      var peripheral = central?.getPeripheral(deviceId)
      if (peripheral != null) {
        var device = BLEDevice(peripheral, this@FlutterMidiCommandPlugin.setupStreamHandler, rxStreamHandler, this@FlutterMidiCommandPlugin.ongoingConnections[deviceId])
        central?.connect(peripheral, device.peripheralCallback)
        connectedDevices[device.id] = device
        discoveredDevices.remove(device.id)
      } else {
        Log.d(TAG, "not found peripheral $deviceId")
        return "Peripheral not found"
      }
    } else if (type == "bonded") {
      // Connect directly to MidiManager
      var peripheral = central?.getPeripheral(deviceId)
      if (peripheral != null) {
        var device = deviceForPeripheral(peripheral)
        if (device != null) {
          midiManager.openBluetoothDevice(device, deviceOpenedListener, handler)
        } else {
          Log.d(TAG, "not found device ${peripheral.address}")
          return "Device not found"
        }
      } else {
        return "Device not found"
      }
    } else if (type == "native") {
      val devices =  midiManager.devices.filter { d -> d.id.toString() == deviceId }
      if (devices.isEmpty()) {
        Log.d(TAG, "not found device $devices")
        return "Device not found"
      } else {
        Log.d(TAG, "open device ${devices[0]}")
        midiManager.openDevice(devices.first(), deviceOpenedListener, handler)
      }
    } else {
      Log.d(TAG, "Can't connect to unknown device type $type")
    }
    return null;
  }

  private fun deviceForPeripheral(peripheral:BluetoothPeripheral) : BluetoothDevice? {
    var device = blManager?.getConnectedDevices(GATT_SERVER)?.filter { it.address == peripheral.address }
    if (device?.isNotEmpty() == true) {
      return device.first()
    }
    return null
  }

  fun teardown() {
    Log.d(TAG, "teardown")

    stopVirtualService()

    connectedDevices.forEach { s, connectedDevice -> connectedDevice.close() }
    connectedDevices.clear()

    Log.d(TAG, "unregisterDeviceCallback")
    midiManager.unregisterDeviceCallback(deviceConnectionCallback)
    Log.d(TAG, "unregister broadcastReceiver")
    try {
      context.unregisterReceiver(broadcastReceiver)
    } catch (e: Exception) {
      // The receiver was not registered.
      // There is nothing to do in that case.
      // Everything is fine.
    }
  }



  fun disconnectDevice(deviceId: String) {
    Log.d(TAG, "disconnect device $deviceId")
    connectedDevices[deviceId]?.also {
      it.close()
      connectedDevices.remove(deviceId)
    }
  }

  fun sendData(data: ByteArray, timestamp: Long?, deviceId: String?) {
    if (deviceId != null) {
      if (connectedDevices.containsKey(deviceId)) {
        connectedDevices[deviceId]?.let {
//          Log.d(TAG, "send midi to $it ${it.id}")
          it.send(data, timestamp)
        }
      } else {
        Log.d(TAG, "no device for id $deviceId")
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
  var bondedDeviceIds = mutableListOf<String>()

    // Reading bonded devices requires BLUETOOTH_CONNECT permissions
      if (ActivityCompat.checkSelfPermission(
        context,
        Manifest.permission.BLUETOOTH_CONNECT
      ) != PackageManager.PERMISSION_GRANTED
    ) {
//      Log.d(TAG, "Missing permissions for BLUETOOTH_CONNECT (bonded device list)")
    } else {
     var bondedDevices = bluetoothAdapter?.getBondedDevices()
     bondedDevices?.forEach {
//      Log.d(TAG, "bonded device ${it.address} type ${it.type} name ${it.name}")
       bondedDeviceIds.add(it.address)
     }


      var connectedGattDevices = blManager?.getConnectedDevices(GATT_SERVER)
      connectedGattDevices?.forEach {
        var id = it.address
  //      Log.d(TAG, "connected gatt device $id")
        if (bondedDeviceIds.contains(id)) {
          list[id] = mapOf(
            "name" to it.name,
            "id" to id,
            "type" to "bonded",
            "connected" to if (connectedDevices.contains(it.address)) "true" else "false",
            "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
            "outputs" to listOf(mapOf("id" to 0, "connected" to false))
          )
        }
      }
    }


    // Discovered BLE devices
    discoveredDevices.entries.forEach {
      var id:String = it.key

//      Log.d(TAG, "discovered device $id")
      if (list.containsKey(id)) {
//        Log.d(TAG, "device already in list $id")
      } else {
//      Log.d(TAG, "add discovered device $id")
        list[id] = it.value
      }
    }

    // Generic MIDI devices
    val devs:Array<MidiDeviceInfo> = midiManager.devices
    devs.forEach {
      var id = NativeDevice.deviceIdForInfo(it)
//      Log.d(TAG, "native device $id")
      if (list.containsKey(id)) {
//        Log.d(TAG, "device already in list $id")
      } else {

//      Log.d(TAG, "add native device from midiManager id $id type ${it.type}")
        list[id] = mapOf(
          "name" to (it.properties.getString(MidiDeviceInfo.PROPERTY_NAME) ?: "-"),
          "id" to id,
          "type" to "native",
          "connected" to if (connectedDevices.contains(id)) "true" else "false",
          "inputs" to listOfPorts(it.inputPortCount),
          "outputs" to listOfPorts(it.outputPortCount)
        )
      }
    }

    connectedDevices.values.forEach{
//      Log.d(TAG, "connected device ${it.id}")
      if (!list.containsKey(it.id)) {
//        Log.d(TAG, "add connected BLE device ${it.id}")
        list[it.id] = mapOf(
          "name" to it.name,
          "id" to it.id,
          "type" to "BLE",
          "connected" to "true",
          "inputs" to listOfPorts(1),
          "outputs" to listOfPorts(1)
        )
      }
    }

//    Log.d(TAG, "list $list")

    return list.values.toList()
  }

  //region MIDI Callbacks

  private val deviceOpenedListener = object : MidiManager.OnDeviceOpenedListener {
    override fun onDeviceOpened(it: MidiDevice?) {
      Log.d(TAG, "onDeviceOpened")
      it?.also {
        val device = NativeDevice(it, this@FlutterMidiCommandPlugin.setupStreamHandler)
        var result = this@FlutterMidiCommandPlugin.ongoingConnections[device.id]
        device.connectWithStreamHandler(rxStreamHandler, result)

        Log.d(TAG, "Opened device id ${device.id}")
        connectedDevices[device.id] = device
        ongoingConnections.remove(device.id)
      }
    }
  }

  private val deviceConnectionCallback = object : MidiManager.DeviceCallback() {

    override fun onDeviceAdded(device: MidiDeviceInfo?) {
      super.onDeviceAdded(device)
      device?.also {
        Log.d(TAG, "MIDI device added $it")
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceFound")
      }
    }

    override fun onDeviceRemoved(device: MidiDeviceInfo?) {
      super.onDeviceRemoved(device)
      device?.also {
        Log.d(TAG, "device removed $it")
        var id = NativeDevice.deviceIdForInfo(it)
        connectedDevices[id]?.also {
          Log.d(TAG, "remove removed device $it")
          connectedDevices.remove(id)
          discoveredDevices.remove(id)
          ongoingConnections.remove(id)
        }
        this@FlutterMidiCommandPlugin.setupStreamHandler.send("deviceLost")
      }
    }

    override fun onDeviceStatusChanged(status: MidiDeviceStatus?) {
      super.onDeviceStatusChanged(status)
      Log.d(TAG, "MIDI device status changed ${status.toString()}")

      status?.also {
        connectedDevices[NativeDevice.deviceIdForInfo(it.deviceInfo)]?.also {
          Log.d(TAG, "update device status $status")
//          it.status = status
        }
      }
      this@FlutterMidiCommandPlugin.setupStreamHandler.send(status.toString())
    }
  }


  //endregion

  //region BLESSED functions

  private fun getBluetoothManager(): BluetoothManager {
    return Objects.requireNonNull(
      context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager,
      "cannot get BluetoothManager"
    )
  }

  private fun isBluetoothEnabled(): Boolean {
    blManager = getBluetoothManager()
    bluetoothAdapter = blManager!!.adapter
      ?: return false

    return bluetoothAdapter!!.isEnabled
  }

  private fun checkPermissions() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      val missingPermissions: Array<String> = getMissingPermissions(getRequiredPermissions())

      Log.d(TAG, "missing permissions ${missingPermissions.map { it }.toList()}")

      if (missingPermissions.isNotEmpty()) {
        ActivityCompat.requestPermissions(activity!!,
          missingPermissions,
          PERMISSIONS_REQUEST_ACCESS_LOCATION
        )
      } else {
        permissionsGranted()
      }
    }
  }

  private fun getMissingPermissions(requiredPermissions: Array<String>): Array<String> {
    val missingPermissions = mutableListOf<String>()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      for (requiredPermission in requiredPermissions) {
        if (context.checkSelfPermission(requiredPermission) !== PackageManager.PERMISSION_GRANTED) {
          missingPermissions.add(requiredPermission)
        }
      }
    }
    return missingPermissions.toTypedArray()
  }

  private fun getRequiredPermissions(): Array<String> {
    val targetSdkVersion: Int = context.applicationInfo.targetSdkVersion

    Log.d(TAG, "targetSDKVersion $targetSdkVersion Build.VERSION.SDK_INT ${Build.VERSION.SDK_INT} Build.VERSION_CODES.S ${Build.VERSION_CODES.S} Build.VERSION_CODES.Q ${Build.VERSION_CODES.Q}")

    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && targetSdkVersion >= Build.VERSION_CODES.S) {
      arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && targetSdkVersion >= Build.VERSION_CODES.Q) {
      arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.BLUETOOTH)
    } else  {
      arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.BLUETOOTH)
    }
  }

  private fun permissionsGranted() {
    // Check if Location services are on because they are required to make scanning work for SDK < 31
    val targetSdkVersion: Int = context.applicationInfo.targetSdkVersion
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && targetSdkVersion < Build.VERSION_CODES.S) {
      if (checkLocationServices()) {
        initBluetoothHandler()
      }
    } else {
      initBluetoothHandler()
    }
  }

  private fun initBluetoothHandler() {
    Log.d(TAG, "init handler")
    // Create BluetoothCentral
    central = BluetoothCentralManager(context, bluetoothCentralManagerCallback, Handler(Looper.getMainLooper()))
    setupStreamHandler.send("bleCentralUp")
  }

  private fun areLocationServicesEnabled(): Boolean {
    val locationManager =
      context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    if (locationManager == null) {

      Log.d(TAG, "could not get location manager")
      return false
    }
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      locationManager.isLocationEnabled
    } else {
      val isGpsEnabled = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)
      val isNetworkEnabled = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
      isGpsEnabled || isNetworkEnabled
    }
  }

  private fun checkLocationServices(): Boolean {
    return if (!areLocationServicesEnabled()) {
      AlertDialog.Builder(activity)
        .setTitle("Location services are not enabled")
        .setMessage("Scanning for Bluetooth peripherals requires locations services to be enabled.") // Want to enable?
        .setPositiveButton(
          "Enable"
        ) { dialogInterface, i ->
          dialogInterface.cancel()
          activity?.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
        }
        .setNegativeButton(
          "Cancel"
        ) { dialog, which -> // if this button is clicked, just close
          // the dialog box and do nothing
          dialog.cancel()
        }
        .create()
        .show()
      false
    } else {
      true
    }
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<String?>,
    grantResults: IntArray
  ) : Boolean {
    // Check if all permission were granted
    var allGranted = true
    for (result in grantResults) {
      if (result != PackageManager.PERMISSION_GRANTED) {
        allGranted = false
        break
      }
    }
    if (allGranted) {
      permissionsGranted()
      return true
    } else {
      AlertDialog.Builder(activity)
        .setTitle("Permission is required for scanning Bluetooth peripherals")
        .setMessage("Please grant permissions")
        .setPositiveButton(
          "Retry"
        ) { dialogInterface, i ->
          dialogInterface.cancel()
          checkPermissions()
        }
        .create()
        .show()
    }
    bluetoothState = "unauthorized"
    return false
  }

  //endregion


  //region BLESSED callbacks

  private val bluetoothCentralManagerCallback: BluetoothCentralManagerCallback =
    object : BluetoothCentralManagerCallback() {
      override fun onConnected(peripheral: BluetoothPeripheral) {
        Log.d(TAG, "connected to ${peripheral.name}")
        var id = peripheral.address
        discoveredDevices.remove(id)
      }

      override fun onConnectionFailed(peripheral: BluetoothPeripheral, status: HciStatus) {
        Log.d(TAG, "connection '${peripheral.name}' failed with status ${status.value}")
        setupStreamHandler.send("connectionFailed")
        ongoingConnections.remove(peripheral.address)
      }

      override fun onDisconnected(peripheral: BluetoothPeripheral, status: HciStatus) {
        Log.d(TAG, "disconnected '${peripheral.name}' with status $status")
        connectedDevices.remove(peripheral.address)
        ongoingConnections.remove(peripheral.address)
        setupStreamHandler.send("deviceDisconnected")
      }

      override fun onDiscovered(peripheral: BluetoothPeripheral, scanResult: ScanResult) {
        Log.d(TAG, "Found peripheral ${peripheral.name}")
        var id = peripheral.address

        var exists = discoveredDevices.containsKey(id)

        discoveredDevices[id] =
          mapOf(
            "name" to peripheral.name,
            "id" to id,
            "type" to "BLE",
            "connected" to if (connectedDevices.contains(peripheral.address)) "true" else "false",
            "inputs" to listOf(mapOf("id" to 0, "connected" to false)),
            "outputs" to listOf(mapOf("id" to 0, "connected" to false))

        )

        if (exists == true) {
          setupStreamHandler.send("deviceUpdated")
        } else {
          setupStreamHandler.send("deviceAppeared")
        }
      }

      override fun onScanFailed(scanFailure: ScanFailure) {
        Log.d(TAG, "scanning failed with error $scanFailure")
        setupStreamHandler.send("BLE scan failed ${scanFailure.value}")
      }
    }

  //endregion
}


