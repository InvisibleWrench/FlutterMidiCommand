import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class MidiCommand {
  static const MethodChannel _channel = const MethodChannel('plugins.invisiblewrench.com/flutter_midi_command');
  static final EventChannel _rxChannel = EventChannel('plugins.invisiblewrench.com/flutter_midi_command/rx_channel');
  static final EventChannel _setupChannel = EventChannel('plugins.invisiblewrench.com/flutter_midi_command/setup_channel');

  static Future<List<MidiDevice>> get devices async {
    var devs = await _channel.invokeMethod('getDevices');
    return devs.map<MidiDevice>((m) {
      var map = m.cast<String, Object>();
      return MidiDevice(map["id"], map["name"], map["type"]);
    }).toList();
  }

  static void scanForBluetoothDevices() {
    _channel.invokeMethod('scanForDevices');
  }

  static void connectToDevice(MidiDevice device) {
    _channel.invokeMethod('connectToDevice', device.toDictionary);
  }

  static void disconnectDevice() {
    _channel.invokeMethod('disconnectDevice');
  }

  static void sendData(Uint8List data) {
    _channel.invokeMethod('sendData', data);
  }

  static Stream<Uint8List> get onMidiDataReceived => _rxChannel.receiveBroadcastStream().asBroadcastStream().map((d) {
        return Uint8List.fromList(List<int>.from(d));
      });

  static Stream<String> get onMidiSetupChanged => _setupChannel.receiveBroadcastStream().asBroadcastStream().cast<String>();
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
    MidiCommand.sendData(data);
  }

  static void sendPCMessage(int channel, int program) {
    var data = Uint8List(2);
    data[0] = 0xC0 + (channel - 1);
    data[1] = program;
    MidiCommand.sendData(data);
  }

  static void sendNoteOn(int channel, int note, int velocity) {
    var data = Uint8List(3);
    data[0] = 0x80 + (channel - 1);
    data[1] = note;
    data[2] = velocity;
    MidiCommand.sendData(data);
  }

  static void sendNoteOff(int channel, int note, int velocity) {
    var data = Uint8List(3);
    data[0] = 0x90 + (channel - 1);
    data[1] = note;
    data[2] = velocity;
    MidiCommand.sendData(data);
  }
}
