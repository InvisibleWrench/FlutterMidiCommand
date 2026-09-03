import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/midi_device.dart';
import 'package:flutter_midi_command_platform_interface/midi_packet.dart';
import 'package:flutter_midi_command_platform_interface/midi_port.dart';
import 'package:flutter_midi_command_platform_interface/midi_setup_change.dart';
import 'package:flutter_midi_command_platform_interface/midi_write_failure.dart';

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
  /// transport never scanned). Lets the transport prepare or release the
  /// matching BLE link by id. Returns the transport's device instance, or null
  /// if unsupported.
  MidiDevice? registerKnownDevice(String id, String name) => null;

  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
    Duration? timeout,
  });
  void disconnectDevice(MidiDevice device);
  void sendData(Uint8List data, {int? timestamp, String? deviceId});

  /// Sends [data] and completes once it has actually been written to the link.
  ///
  /// [sendData] returns as soon as the data is queued, which is fine for live
  /// MIDI but leaves a bulk transfer pacing itself against a guess. Awaiting
  /// delivery lets it send exactly as fast as the link drains.
  ///
  /// Transports that cannot observe delivery fall back to [sendData] and
  /// complete immediately.
  Future<void> sendDataAwaitingDelivery(
    Uint8List data, {
    int? timestamp,
    String? deviceId,
  }) async => sendData(data, timestamp: timestamp, deviceId: deviceId);
  Stream<MidiPacket> get onMidiDataReceived;
  Stream<MidiSetupChange> get onMidiSetupChanged;

  /// Writes the transport accepted from [sendData] but could not deliver.
  ///
  /// [sendData] is fire-and-forget, so without this a dropped write is
  /// invisible to the caller. Transports that cannot detect write failures
  /// leave the default empty stream in place.
  Stream<MidiWriteFailure> get onWriteFailure => const Stream.empty();

  void teardown();
}
