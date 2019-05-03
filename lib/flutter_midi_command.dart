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
  MidiCommand.private(this._channel, this._rxChannel, this._setupChannel) {
    print("private construct $_rxChannel ${this._rxChannel}");

//    _rxChannel.receiveBroadcastStream().listen((data) {
//      print("data from midi $data");
//
//      var status = data[0];
//
//      if (data.length >= 3) {
//        var ctrlParam = data[1];
//        var d2 = data[2];
//        var type = status == 0xF8 ? 0xF8 : status & 0xF0; // beat clock or filter out channel
//        var channel = status & 0x0F; // channel only
//
//        print("data type $type");
//        print("data channel $channel");
//
//        var subs = _messageSubscriptions.where((ms) {
//          return (ms.type == type) &&
//              (ms.channel > -1 ? ms.channel == channel: true) &&
//              (ms.controlParameter > -1 ? ms.controlParameter == ctrlParam: true);
//        }).toList(growable: false);
//
//        subs.forEach((ms) {
//          print(ms);
//          print("add $data to $ms");
//
//          if (ms.streamCtrl.isClosed) {
//            print("stream is closed, remove sub");
//            _messageSubscriptions.remove(ms);
//          } else {
//            ms.streamCtrl.add(d2);
//          }
//        });
//      }
//    });
  }

  static MidiCommand _instance;

  final MethodChannel _channel;
  final EventChannel _rxChannel;
  final EventChannel _setupChannel;

  Stream<Uint8List> _rxStream;
  Stream<String> _setupStream;

//  List<MessageSubscription> _messageSubscriptions = List<MessageSubscription>();

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
  void startScanningForBluetoothDevices() {
    _channel.invokeMethod('scanForDevices');
  }

  void stopScanningForBluetoothDevices() {
    _channel.invokeMethod('stopScanForDevices');
  }

  /// Connects to the device.
  void connectToDevice(MidiDevice device) {
    _channel.invokeMethod('connectToDevice', device.toDictionary);
  }

  /// Disconnects from the device.
  void disconnectDevice() {
    _channel.invokeMethod('disconnectDevice');
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

//  MessageSubscription subscribeToMIDIMessages({MessageType type, int channel = -1, int controlParameter = -1}) {
//    print("subscribe $type $channel $controlParameter");
//    var sub = MessageSubscription(streamCtrl: StreamController<int>(), type: valueForMessageType(type), channel: channel, controlParameter: controlParameter);
//    _messageSubscriptions.add(sub);
//    return sub;
//  }

//  int valueForMessageType(MessageType type) {
//    switch (type) {
//      case MessageType.CC:
//        return 0xB0;
//      case MessageType.PC:
//        return 0xC0;
//      case MessageType.NoteOn:
//        return 0x80;
//      case MessageType.NoteOff:
//        return 0x90;
//      case MessageType.NRPN:
//        return 0xB0;
//      case MessageType.Beat:
//        return 0xF8;
//      case MessageType.SYSEX:
//        return 0;
//    }
//  }
}

//class MessageSubscription {
//  StreamController<int> streamCtrl;
//  int type;
//  int channel = -1;
//  int controlParameter = -1;
//
//  MessageSubscription({this.streamCtrl, this.type, this.channel, this.controlParameter});
//}

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

//enum MessageType { CC, PC, NoteOn, NoteOff, NRPN, SYSEX, Beat }
//
//class MidiMessage {
//  Uint8List data;
//
//  MidiMessage();
//
//  void send() {
//    MidiCommand().sendData(data);
//  }
//}
//
//class CCMessage extends MidiMessage {
//  int channel = 0;
//  int controller = 0;
//  int value = 0;
//
//  CCMessage({this.channel = 0, this.controller = 0, this.value = 0});
//
//  @override
//  void send() {
//    data = Uint8List(3);
//    data[0] = 0xB0 + channel;
//    data[1] = controller;
//    data[2] = value;
//    print(data);
//    super.send();
//  }
//}
//
//class PCMessage extends MidiMessage {
//  int channel = 0;
//  int program = 0;
//
//  PCMessage({this.channel = 0, this.program = 0});
//
//  @override
//  void send() {
//    data = Uint8List(2);
//    data[0] = 0xC0 + channel;
//    data[1] = program;
//    super.send();
//  }
//}
//
//class NoteOnMessage extends MidiMessage {
//  int channel = 0;
//  int note = 0;
//  int velocity = 0;
//
//  NoteOnMessage({this.channel = 0, this.note = 0, this.velocity = 0});
//
//  @override
//  void send() {
//    data = Uint8List(3);
//    data[0] = 0x80 + channel;
//    data[1] = note;
//    data[2] = velocity;
//    super.send();
//  }
//}
//
//class NoteOffMessage extends MidiMessage {
//  int channel = 0;
//  int note = 0;
//  int velocity = 0;
//
//  NoteOffMessage({this.channel = 0, this.note = 0, this.velocity = 0});
//
//  @override
//  void send() {
//    data = Uint8List(3);
//    data[0] = 0x90 + channel;
//    data[1] = note;
//    data[2] = velocity;
//    super.send();
//  }
//}
//
//class SysExMessage extends MidiMessage {
//  List<int> headerData = [];
//  int value = 0;
//
//  SysExMessage({this.headerData = const [], this.value = 0});
//
//  @override
//  void send() {
//    data = headerData;
//    data.insert(0, 0xF0); // Start byte
//    data.addAll(_bytesForValue(value));
//    data.add(0xF7); // End byte
//    super.send();
//  }
//
//  Int8List _bytesForValue(int value) {
//    print("bytes for value $value");
//    var bytes = Int8List(5);
//
//    int absValue = value.abs();
//
//    int base256 = (absValue ~/ 256);
//    int left = absValue - (base256 * 256);
//    int base1 = left % 128;
//    left -= base1;
//    int base2 = left ~/ 2;
//
//    if (value < 0) {
//      bytes[0] = 0x7F;
//      bytes[1] = 0x7F;
//      bytes[2] = 0x7F - base256;
//      bytes[3] = 0x7F - base2;
//      bytes[4] = 0x7F - base1;
//    } else {
//      bytes[2] = base256;
//      bytes[3] = base2;
//      bytes[4] = base1;
//    }
//    return bytes;
//  }
//}
//
//class NRPNMessage extends MidiMessage {
//  int channel = 0;
//  int parameter = 0;
//  int value = 0;
//
//  NRPNMessage({this.channel = 0, this.parameter = 0, this.value = 0});
//
//  @override
//  void send() {
//    data = Uint8List(12);
//    // Data Entry MSB
//    data[0] = 0xB0 + channel;
//    data[1] = 0x63;
//    data[2] = parameter ~/ 128;
//
//    // Data Entry LSB
//    data[3] = 0xB0 + channel;
//    data[4] = 0x62;
//    data[5] = parameter - (data[2] * 128);
//
//    // Data Value MSB
//    data[6] = 0xB0 + channel;
//    data[7] = 0x06;
//    data[8] = value & 0x7F;
//
//    // Data Value LSB
//    data[9] = 0xB0 + channel;
//    data[10] = 0x38;
//    data[11] = value & 0x3F80;
//
//    super.send();
//  }
//}
//
//class NRPNHexMessage extends MidiMessage {
//  int channel = 0;
//  int parameterMSB = 0;
//  int parameterLSB = 0;
//  int valueMSB = 0;
//  int valueLSB = -1;
//
//  NRPNHexMessage({this.channel = 0, this.parameterMSB = 0, this.parameterLSB = 0, this.valueMSB = 0, this.valueLSB = 0});
//
//  @override
//  void send() {
//    var length = valueLSB > -1 ? 12 : 9;
//    data = Uint8List(length);
//    // Data Entry MSB
//    data[0] = 0xB0 + channel;
//    data[1] = 0x63;
//    data[2] = parameterMSB;
//
//    // Data Entry LSB
//    data[3] = 0xB0 + channel;
//    data[4] = 0x62;
//    data[5] = parameterLSB;
//
//    // Data Value MSB
//    data[6] = 0xB0 + channel;
//    data[7] = 0x06;
//    data[8] = valueMSB;
//
//    // Data Value LSB
//    if (valueLSB > -1) {
//      data[9] = 0xB0 + channel;
//      data[10] = 0x38;
//      data[11] = valueLSB;
//    }
//
//    super.send();
//  }
//}
