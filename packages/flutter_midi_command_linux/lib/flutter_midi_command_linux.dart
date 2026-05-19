import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:midi/midi.dart';

/// Test seam for deterministic ALSA discovery without touching real hardware.
typedef LinuxAlsaDeviceDiscovery = List<LinuxAlsaMidiDevice> Function();

class LinuxAlsaMidiPacket {
  const LinuxAlsaMidiPacket(this.data, this.timestamp);

  final Uint8List data;
  final int timestamp;
}

abstract class LinuxAlsaMidiDevice {
  String get id;
  int get cardId;
  int get deviceId;
  String get name;
  List<String> get inputPorts;
  List<String> get outputPorts;
  Stream<LinuxAlsaMidiPacket> get receivedMessages;

  Future<bool> connect();
  void send(Uint8List midiMessage);
  Future<void> disconnect();
}

class _AlsaMidiDeviceAdapter implements LinuxAlsaMidiDevice {
  _AlsaMidiDeviceAdapter(this._device);

  final AlsaMidiDevice _device;

  @override
  String get id => AlsaMidiDevice.hardwareId(cardId, deviceId);

  @override
  int get cardId => _device.cardId;

  @override
  int get deviceId => _device.deviceId;

  @override
  String get name => _device.name;

  @override
  List<String> get inputPorts => _device.inputPorts;

  @override
  List<String> get outputPorts => _device.outputPorts;

  @override
  Stream<LinuxAlsaMidiPacket> get receivedMessages => _device.receivedMessages
      .map((message) => LinuxAlsaMidiPacket(message.data, message.timestamp));

  @override
  Future<bool> connect() => _device.connect();

  @override
  void send(Uint8List midiMessage) => _device.send(midiMessage);

  @override
  Future<void> disconnect() async {
    _device.disconnect();
  }
}

List<LinuxAlsaMidiDevice> _discoverAlsaDevices() {
  return AlsaMidiDevice.getDevices().map(_AlsaMidiDeviceAdapter.new).toList();
}

class LinuxMidiDevice extends MidiDevice {
  factory LinuxMidiDevice(
    AlsaMidiDevice device,
    int cardId,
    int deviceId,
    String name,
    MidiDeviceType type,
    StreamController<MidiPacket> rxStreamCtrl,
    bool connected,
  ) {
    return LinuxMidiDevice.fromAlsaDevice(
      _AlsaMidiDeviceAdapter(device),
      type,
      rxStreamCtrl,
      connected,
    );
  }

  LinuxMidiDevice.fromAlsaDevice(
    this._device,
    MidiDeviceType type,
    this._rxStreamCtrl,
    bool connected,
  ) : cardId = _device.cardId,
      deviceId = _device.deviceId,
      super(_device.id, _device.name, type, connected) {
    var i = 0;
    for (final _ in _device.inputPorts) {
      inputPorts.add(MidiPort(++i, MidiPortType.IN));
    }
    i = 0;
    for (final _ in _device.outputPorts) {
      outputPorts.add(MidiPort(++i, MidiPortType.OUT));
    }
  }

  final StreamController<MidiPacket> _rxStreamCtrl;
  final int cardId;
  final int deviceId;
  final LinuxAlsaMidiDevice _device;
  StreamSubscription<LinuxAlsaMidiPacket>? _rxSubscription;

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

  void send(Uint8List buffer, int length) {
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
  FlutterMidiCommandLinux({LinuxAlsaDeviceDiscovery? deviceDiscovery})
    : _deviceDiscovery = deviceDiscovery ?? _discoverAlsaDevices {
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
  final LinuxAlsaDeviceDiscovery _deviceDiscovery;

  /// The linux implementation of [MidiCommandPlatform]
  ///
  /// This class implements the `package:flutter_midi_command_platform_interface` functionality for linux
  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    return _deviceDiscovery().map((alsaMidiDevice) {
      final connectedDevice = _connectedDevices[alsaMidiDevice.id];
      if (connectedDevice != null) {
        connectedDevice.connected = true;
        return connectedDevice;
      }

      return LinuxMidiDevice.fromAlsaDevice(
        alsaMidiDevice,
        MidiDeviceType.serial,
        _rxStreamController,
        false,
      );
    }).toList();
  }

  /// Connects to the device.
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

  /// Disconnects from the device.
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
    for (final device in _connectedDevices.values.toList()) {
      unawaited(device.disconnect());
    }
    _connectedDevices.clear();
    _addSetupEvent("deviceDisconnected");
    unawaited(_setupStreamController.close());
    unawaited(_rxStreamController.close());
  }

  /// Sends data to the currently connected device.
  ///
  /// Data is an UInt8List of individual MIDI command bytes.
  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    if (deviceId != null) {
      _connectedDevices[deviceId]?.send(data, data.length);
      return;
    }

    for (final device in _connectedDevices.values) {
      device.send(data, data.length);
    }
  }

  /// Stream firing events whenever a midi package is received.
  ///
  /// The event contains the raw bytes contained in the MIDI package.
  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStream;

  /// Stream firing events whenever a change in the MIDI setup occurs.
  ///
  /// For example, when a new BLE devices is discovered.
  @override
  Stream<String>? get onMidiSetupChanged => _setupStream;

  /// Creates a virtual MIDI source.
  @override
  void addVirtualDevice({String? name}) {}

  /// Removes a previously created virtual MIDI source.
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
