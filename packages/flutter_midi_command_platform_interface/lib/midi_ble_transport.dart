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

  /// Registers a BLE device that may currently only be known via the host
  /// platform (for example a bonded peripheral exposed by CoreMIDI that this
  /// transport never scanned). Lets the transport keep it listed so it remains
  /// reconnectable by id after the host platform drops it. Returns the
  /// transport's device instance, or null if unsupported.
  MidiDevice? registerKnownDevice(String id, String name) => null;

  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
    Duration? timeout,
  });
  void disconnectDevice(MidiDevice device);
  void sendData(Uint8List data, {int? timestamp, String? deviceId});
  Stream<MidiPacket> get onMidiDataReceived;
  Stream<MidiSetupChange> get onMidiSetupChanged;
  void teardown();
}
