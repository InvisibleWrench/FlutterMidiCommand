import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

import 'src/alsa_seq_linux_device.dart';

/// Test seam for deterministic ALSA discovery without touching real hardware.
typedef LinuxMidiDeviceDiscovery = List<LinuxMidiPortDevice> Function();

class LinuxMidiPacket {
  const LinuxMidiPacket(this.data, this.timestamp);

  final Uint8List data;
  final int timestamp;
}

abstract class LinuxMidiPortDevice {
  String get id;
  String get name;
  bool get hasInput;
  bool get hasOutput;
  Stream<LinuxMidiPacket> get receivedMessages;

  Future<bool> connect();
  void send(Uint8List midiMessage);
  Future<void> disconnect();
}

List<LinuxMidiPortDevice> _discoverLinuxMidiDevices() {
  return AlsaSeqLinuxDevice.getDevices();
}

class LinuxMidiDevice extends MidiDevice {
  LinuxMidiDevice.fromPortDevice(
    this._device,
    MidiDeviceType type,
    this._rxStreamCtrl,
    bool connected,
  ) : super(_device.id, _device.name, type, connected) {
    if (_device.hasInput) {
      inputPorts.add(MidiPort(0, MidiPortType.IN));
    }
    if (_device.hasOutput) {
      outputPorts.add(MidiPort(0, MidiPortType.OUT));
    }
  }

  final StreamController<MidiPacket> _rxStreamCtrl;
  final LinuxMidiPortDevice _device;
  StreamSubscription<LinuxMidiPacket>? _rxSubscription;

  Future<bool> connect() async {
    if (_rxSubscription != null) {
      return true;
    }

    final success = await _device.connect();
    if (!success) {
      return false;
    }

    connected = true;
    _rxSubscription = _device.receivedMessages.listen((event) {
      if (!connected || _rxStreamCtrl.isClosed) {
        return;
      }
      _rxStreamCtrl.add(MidiPacket(event.data, event.timestamp, this));
    });
    return true;
  }

  void send(Uint8List buffer) {
    _device.send(buffer);
  }

  Future<void> disconnect() async {
    connected = false;
    final subscription = _rxSubscription;
    _rxSubscription = null;
    await subscription?.cancel();
    await _device.disconnect();
  }
}

class FlutterMidiCommandLinux extends MidiCommandPlatform {
  FlutterMidiCommandLinux({LinuxMidiDeviceDiscovery? deviceDiscovery})
    : _deviceDiscovery = deviceDiscovery ?? _discoverLinuxMidiDevices {
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
  }

  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late final Stream<MidiPacket> _rxStream;
  final StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();
  late final Stream<String> _setupStream;

  final Map<String, LinuxMidiDevice> _connectedDevices =
      <String, LinuxMidiDevice>{};
  final LinuxMidiDeviceDiscovery _deviceDiscovery;

  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    return _deviceDiscovery()
        .map((portDevice) {
          final connectedDevice = _connectedDevices[portDevice.id];
          if (connectedDevice != null) {
            connectedDevice
              ..name = portDevice.name
              ..connected = true;
            return connectedDevice;
          }

          return LinuxMidiDevice.fromPortDevice(
            portDevice,
            MidiDeviceType.serial,
            _rxStreamController,
            false,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    if (device is! LinuxMidiDevice) {
      return;
    }
    if (_connectedDevices.containsKey(device.id)) {
      return;
    }

    final success = await device.connect();
    if (success) {
      _connectedDevices[device.id] = device;
      _addSetupEvent("deviceConnected");
      return;
    }

    throw StateError('Failed to connect Linux MIDI device ${device.id}.');
  }

  @override
  void disconnectDevice(MidiDevice device, {bool remove = true}) {
    final linuxDevice = _connectedDevices[device.id];
    if (linuxDevice == null) {
      return;
    }

    if (remove) {
      _connectedDevices.remove(device.id);
      _addSetupEvent("deviceDisconnected");
    }
    unawaited(linuxDevice.disconnect());
  }

  @override
  void teardown() {
    final connected = _connectedDevices.values.toList(growable: false);
    for (final device in connected) {
      unawaited(device.disconnect());
    }
    _connectedDevices.clear();
    AlsaSeqLinuxDevice.closeSharedContext();
    _addSetupEvent("deviceDisconnected");
    unawaited(_setupStreamController.close());
    unawaited(_rxStreamController.close());
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      _connectedDevices[deviceId]?.send(data);
      return;
    }

    for (final device in _connectedDevices.values) {
      device.send(data);
    }
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStream;

  @override
  Stream<String>? get onMidiSetupChanged => _setupStream;

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => null;

  @override
  void setNetworkSessionEnabled(bool enabled) {}

  void _addSetupEvent(String event) {
    if (!_setupStreamController.isClosed) {
      _setupStreamController.add(event);
    }
  }
}
