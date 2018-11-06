import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:meta/meta.dart' show visibleForTesting;

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

  @visibleForTesting
  MidiCommand.private(this._channel, this._rxChannel, this._setupChannel);

  static MidiCommand _instance;

  final MethodChannel _channel;
  final EventChannel _rxChannel;
  final EventChannel _setupChannel;

  Future<List<MidiDevice>> get devices async {
    var devs = await _channel.invokeMethod('getDevices');
    return devs.map<MidiDevice>((m) {
      var map = m.cast<String, Object>();
      return MidiDevice(map["id"], map["name"], map["type"]);
    }).toList();
  }

  void scanForBluetoothDevices() {
    _channel.invokeMethod('scanForDevices');
  }

  void connectToDevice(MidiDevice device) {
    _channel.invokeMethod('connectToDevice', device.toDictionary);
  }

  void disconnectDevice() {
    _channel.invokeMethod('disconnectDevice');
  }

  void sendData(Uint8List data) {
    _channel.invokeMethod('sendData', data);
  }

  Stream<Uint8List> get onMidiDataReceived => _rxChannel.receiveBroadcastStream().asBroadcastStream().map((d) {
        return Uint8List.fromList(List<int>.from(d));
      });

  Stream<String> get onMidiSetupChanged => _setupChannel.receiveBroadcastStream().asBroadcastStream().cast<String>();
}

class MidiDevice {
  String name;
  String id;
  String type;

  MidiDevice(this.id, this.name, this.type);

  Map<String, Object> get toDictionary {
    return {"name": name, "id": id, "type": type};
  }
}

class MidiCommandHelper {
  static void sendCCMessage(int channel, int controller, int value) {
    var data = Uint8List(3);
    data[0] = 0xB0 + (channel - 1);
    data[1] = controller;
    data[2] = value;
    MidiCommand().sendData(data);
  }

  static void sendPCMessage(int channel, int program) {
    var data = Uint8List(2);
    data[0] = 0xC0 + (channel - 1);
    data[1] = program;
    MidiCommand().sendData(data);
  }

  static void sendNoteOn(int channel, int note, int velocity) {
    var data = Uint8List(3);
    data[0] = 0x80 + (channel - 1);
    data[1] = note;
    data[2] = velocity;
    MidiCommand().sendData(data);
  }

  static void sendNoteOff(int channel, int note, int velocity) {
    var data = Uint8List(3);
    data[0] = 0x90 + (channel - 1);
    data[1] = note;
    data[2] = velocity;
    MidiCommand().sendData(data);
  }
}
