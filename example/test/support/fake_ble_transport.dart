import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

class FakeBleTransport implements MidiBleTransport {
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  final StreamController<MidiSetupChange> _setupStreamController =
      StreamController<MidiSetupChange>.broadcast();
  final StreamController<String> _bluetoothStateController =
      StreamController<String>.broadcast();

  final MidiDevice bleDevice = MidiDevice(
    'ble-1',
    'Test BLE Device',
    MidiDeviceType.ble,
    false,
  )
    ..inputPorts = <MidiPort>[MidiPort(0, MidiPortType.IN)]
    ..outputPorts = <MidiPort>[MidiPort(0, MidiPortType.OUT)];

  bool bluetoothStarted = false;
  bool scanning = false;
  int startBluetoothCallCount = 0;
  int startScanCallCount = 0;
  int stopScanCallCount = 0;

  @override
  Future<void> startBluetooth() async {
    bluetoothStarted = true;
    startBluetoothCallCount += 1;
    scheduleMicrotask(() {
      _bluetoothStateController.add('poweredOn');
    });
  }

  @override
  Future<String> bluetoothState() async =>
      bluetoothStarted ? 'poweredOn' : 'unknown';

  @override
  Stream<String> get onBluetoothStateChanged =>
      _bluetoothStateController.stream;

  @override
  Future<void> startScanningForBluetoothDevices() async {
    scanning = true;
    startScanCallCount += 1;
    _setupStreamController.add(MidiSetupChange.deviceAppeared);
  }

  @override
  void stopScanningForBluetoothDevices() {
    scanning = false;
    stopScanCallCount += 1;
  }

  @override
  Future<List<MidiDevice>> get devices async =>
      scanning ? <MidiDevice>[bleDevice] : <MidiDevice>[];

  @override
  MidiDevice? registerKnownDevice(String id, String name) => null;

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    device.setConnectionState(MidiConnectionState.connected);
  }

  @override
  void disconnectDevice(MidiDevice device) {
    device.setConnectionState(MidiConnectionState.disconnected);
  }

  @override
  void sendData(Uint8List data, {String? deviceId, int? timestamp}) {}

  @override
  Stream<MidiPacket> get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<MidiSetupChange> get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  void teardown() {
    scanning = false;
    bluetoothStarted = false;
  }
}
