import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

class FakeMidiPlatform extends MidiCommandPlatform {
  FakeMidiPlatform({bool? networkEnabled})
      : networkEnabled = networkEnabled ?? false {
    devicesList = <MidiDevice>[
      MidiDevice(
        'serial-1',
        'Test Serial Device',
        MidiDeviceType.serial,
        false,
      ),
    ];
  }

  late List<MidiDevice> devicesList;
  final List<String> connectedDeviceIds = <String>[];
  final List<String> disconnectedDeviceIds = <String>[];
  final List<String?> addedVirtualDeviceNames = <String?>[];
  final List<String?> removedVirtualDeviceNames = <String?>[];
  final List<bool> networkEnabledChanges = <bool>[];
  final List<Uint8List> sentMessages = <Uint8List>[];
  final List<String?> sentDeviceIds = <String?>[];
  final List<int?> sentTimestamps = <int?>[];
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  final StreamController<MidiSetupChange> _setupStreamController =
      StreamController<MidiSetupChange>.broadcast();
  bool networkEnabled;
  int devicesCallCount = 0;
  var _isClosed = false;

  @override
  Future<List<MidiDevice>?> get devices async {
    devicesCallCount += 1;
    return devicesList;
  }

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
    for (final device in devicesList) {
      device.setConnectionState(MidiConnectionState.disconnected);
    }
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _rxStreamController.close();
    _setupStreamController.close();
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    sentMessages.add(Uint8List.fromList(data));
    sentDeviceIds.add(deviceId);
    sentTimestamps.add(timestamp);
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<MidiSetupChange>? get onMidiSetupChanged =>
      _setupStreamController.stream;

  @override
  void addVirtualDevice({String? name}) {
    addedVirtualDeviceNames.add(name);
  }

  @override
  void removeVirtualDevice({String? name}) {
    removedVirtualDeviceNames.add(name);
  }

  @override
  Future<bool?> get isNetworkSessionEnabled async => networkEnabled;

  @override
  void setNetworkSessionEnabled(bool enabled) {
    networkEnabled = enabled;
    networkEnabledChanges.add(enabled);
  }

  void emitSetupChange(MidiSetupChange change) {
    _setupStreamController.add(change);
  }

  void emitPacket(
    String deviceId,
    List<int> data, {
    int timestamp = 0,
  }) {
    final device =
        devicesList.firstWhere((candidate) => candidate.id == deviceId);
    _rxStreamController.add(
      MidiPacket(Uint8List.fromList(data), timestamp, device),
    );
  }
}
