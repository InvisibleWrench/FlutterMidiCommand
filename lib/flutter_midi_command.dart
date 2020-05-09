import 'dart:async';

import 'package:flutter/services.dart';
import 'dart:typed_data';

class MidiCommand {
  factory MidiCommand() {
    if (_instance == null) {
      final MethodChannel methodChannel = const MethodChannel('plugins.invisiblewrench.com/flutter_midi_command');
      final EventChannel rxChannel = EventChannel('plugins.invisiblewrench.com/flutter_midi_command/rx_channel');
      final EventChannel setupChannel = EventChannel('plugins.invisiblewrench.com/flutter_midi_command/setup_channel');
      _instance = MidiCommand.private(methodChannel, rxChannel, setupChannel);
    }
    return _instance;
  }

  MidiCommand.private(this._channel, this._rxChannel, this._setupChannel) {
    print("private construct $_rxChannel ${this._rxChannel}");
  }

  static MidiCommand _instance;

  final MethodChannel _channel;
  final EventChannel _rxChannel;
  final EventChannel _setupChannel;

  Stream<Uint8List> _rxStream;
  Stream<String> _setupStream;

  /// Gets a list of available MIDI devices and returns it.
  Future<List<MidiDevice>> get devices async {
    var devs = await _channel.invokeMethod('getDevices');
    return devs.map<MidiDevice>((m) {
      var map = m.cast<String, Object>();
      return MidiDevice(map["id"], map["name"], map["type"], map["connected"] == "true");
    }).toList();
  }

  /// Starts scanning for BLE MIDI devices.
  ///
  /// Found devices will be included in the list returned by [devices].
  Future<void> startScanningForBluetoothDevices() async {
    try {
      await _channel.invokeMethod('scanForDevices');
    } on PlatformException catch (e) {
      throw (e.message);
    }
  }

  void stopScanningForBluetoothDevices() {
    _channel.invokeMethod('stopScanForDevices');
  }

  /// Connects to the device.
  void connectToDevice(MidiDevice device) {
    _channel.invokeMethod('connectToDevice', device.toDictionary);
  }

  /// Disconnects from the device.
  void disconnectDevice(MidiDevice device) {
    _channel.invokeMethod('disconnectDevice', device.toDictionary);
  }

  void teardown() {
    _channel.invokeMethod('teardown');
  }

  /// Sends data to the currently connected device.
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  void sendData(Uint8List data) {
    print("send $data");
    _channel.invokeMethod('sendData', data);
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  Stream<Uint8List> get onMidiDataReceived {
    print("get on midi data");
    _rxStream ??= _rxChannel.receiveBroadcastStream().map<Uint8List>((d) {
      //      print("data $d");
      return Uint8List.fromList(List<int>.from(d));
    });
    return _rxStream;
  }

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  Stream<String> get onMidiSetupChanged {
    _setupStream ??= _setupChannel.receiveBroadcastStream().cast<String>();
    return _setupStream;
  }
}

/// MIDI device data.
class MidiDevice {
  String name;
  String id;
  String type;
  bool connected;

  MidiDevice(this.id, this.name, this.type, this.connected);

  Map<String, Object> get toDictionary {
    return {"name": name, "id": id, "type": type};
  }
}
