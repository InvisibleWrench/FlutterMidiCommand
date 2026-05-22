import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

class FakeMidiPlatform extends MidiCommandPlatform {
  final MidiDevice device = MidiDevice(
    'serial-1',
    'Test Serial Device',
    MidiDeviceType.serial,
    false,
  );

  final List<String> connectedDeviceIds = <String>[];
  final List<String> disconnectedDeviceIds = <String>[];
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  final StreamController<MidiSetupChange> _setupStreamController =
      StreamController<MidiSetupChange>.broadcast();
  var _isClosed = false;

  @override
  Future<List<MidiDevice>?> get devices async => <MidiDevice>[device];

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    connectedDeviceIds.add(device.id);
    device.setConnectionState(MidiConnectionState.connected);
  }

  @override
  void disconnectDevice(MidiDevice device) {
    disconnectedDeviceIds.add(device.id);
    device.setConnectionState(MidiConnectionState.disconnected);
  }

  @override
  void teardown() {
    device.setConnectionState(MidiConnectionState.disconnected);
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _rxStreamController.close();
    _setupStreamController.close();
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {}

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<MidiSetupChange>? get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => false;

  @override
  void setNetworkSessionEnabled(bool enabled) {}
}
