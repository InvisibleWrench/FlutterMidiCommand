import 'dart:async';

import 'dart:typed_data';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
export 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart'
    show MidiDevice;

class MidiCommand {
  factory MidiCommand() {
    if (_instance == null) {
      _instance = MidiCommand._();
    }
    return _instance;
  }

  MidiCommand._();

  static MidiCommand _instance;

  static MidiCommandPlatform get _platform => MidiCommandPlatform.instance;

  StreamController<Uint8List> _txStreamCtrl = StreamController.broadcast();

  /// Gets a list of available MIDI devices and returns it.
  Future<List<MidiDevice>> get devices async {
    return _platform.devices;
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    return _platform.startScanningForBluetoothDevices();
  }

  /// Stop scanning for BLE MIDI devices.
  void stopScanningForBluetoothDevices() {
    _platform.stopScanningForBluetoothDevices();
  }

  /// Connects to the device.
  void connectToDevice(MidiDevice device) {
    _platform.connectToDevice(device);
  }

  /// Disconnects from the device.
  void disconnectDevice(MidiDevice device) {
    _platform.disconnectDevice(device);
  }

  void teardown() {
    _platform.teardown();
  }

  /// Sends data to the currently connected device.
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  void sendData(Uint8List data) {
    _platform.sendData(data);
    _txStreamCtrl.add(data);
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  Stream<Uint8List> get onMidiDataReceived {
    return _platform.onMidiDataReceived;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  Stream<String> get onMidiSetupChanged {
    return _platform.onMidiSetupChanged;
  }

  /// Stream firing events whenever a midi package is sent.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  Stream<Uint8List> get onMidiDataSent {
    return _txStreamCtrl.stream;
  }
}
