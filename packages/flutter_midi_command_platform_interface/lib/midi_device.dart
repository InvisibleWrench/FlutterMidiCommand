import 'dart:async';

import 'package:flutter_midi_command_platform_interface/midi_port.dart';

enum MidiDeviceType { serial, ble, virtual, ownVirtual, network, unknown }

enum MidiConnectionState { disconnected, connecting, connected, disconnecting }

extension MidiDeviceTypeWire on MidiDeviceType {
  String get wireValue {
    switch (this) {
      case MidiDeviceType.serial:
        return 'native';
      case MidiDeviceType.ble:
        return 'BLE';
      case MidiDeviceType.virtual:
        return 'virtual';
      case MidiDeviceType.ownVirtual:
        return 'own-virtual';
      case MidiDeviceType.network:
        return 'network';
      case MidiDeviceType.unknown:
        return 'unknown';
    }
  }

  static MidiDeviceType fromWireValue(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? 'unknown';
    switch (normalized) {
      case 'ble':
      case 'bluetooth':
      case 'bonded':
        return MidiDeviceType.ble;
      case 'native':
      case 'serial':
        return MidiDeviceType.serial;
      case 'virtual':
        return MidiDeviceType.virtual;
      case 'own-virtual':
      case 'ownvirtual':
        return MidiDeviceType.ownVirtual;
      case 'network':
        return MidiDeviceType.network;
      default:
        return MidiDeviceType.unknown;
    }
  }
}

class MidiDevice {
  String name;
  String id;
  MidiDeviceType type;
  List<MidiPort> inputPorts = [];
  List<MidiPort> outputPorts = [];
  final StreamController<MidiConnectionState> _connectionStateController =
      StreamController<MidiConnectionState>.broadcast();
  MidiConnectionState _connectionState;

  MidiDevice(this.id, this.name, this.type, bool connected)
    : _connectionState =
          connected
              ? MidiConnectionState.connected
              : MidiConnectionState.disconnected;

  Stream<MidiConnectionState> get onConnectionStateChanged =>
      _connectionStateController.stream;

  MidiConnectionState get connectionState => _connectionState;

  bool get connected => _connectionState == MidiConnectionState.connected;

  set connected(bool value) {
    setConnectionState(
      value ? MidiConnectionState.connected : MidiConnectionState.disconnected,
    );
  }

  void setConnectionState(MidiConnectionState value) {
    if (_connectionState == value) {
      return;
    }
    _connectionState = value;
    _connectionStateController.add(value);
  }

  void dispose() {
    _connectionStateController.close();
  }
}
