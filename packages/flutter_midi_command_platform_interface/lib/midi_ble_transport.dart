import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/midi_device.dart';
import 'package:flutter_midi_command_platform_interface/midi_packet.dart';
import 'package:flutter_midi_command_platform_interface/midi_port.dart';
import 'package:flutter_midi_command_platform_interface/midi_setup_change.dart';

/// BLE transport contract consumed by `MidiCommand`.
///
/// This is intentionally separate from `MidiCommandPlatform` so native
/// platform wrappers can remain focused on serial/native MIDI stacks while BLE
/// is provided by shared Dart implementations (for example universal_ble).
abstract class MidiBleTransport {
  Future<void> startBluetooth();
  Future<String> bluetoothState();
  Stream<String> get onBluetoothStateChanged;
  Future<void> startScanningForBluetoothDevices();
  void stopScanningForBluetoothDevices();
  Future<List<MidiDevice>> get devices;
  Future<void> connectToDevice(MidiDevice device, {List<MidiPort>? ports});
  void disconnectDevice(MidiDevice device);
  void sendData(Uint8List data, {int? timestamp, String? deviceId});
  Stream<MidiPacket> get onMidiDataReceived;
  Stream<MidiSetupChange> get onMidiSetupChanged;
  void teardown();
}
