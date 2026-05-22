import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';

import 'src/alsa_seq_linux_device.dart';

/// Test seam for deterministic ALSA discovery without touching real hardware.
typedef LinuxMidiDeviceDiscovery = List<LinuxMidiPortDevice> Function();

/// Test seam for deterministic ALSA hotplug notifications.
typedef LinuxMidiDeviceMonitor = Stream<void> Function();

Stream<void> _monitorLinuxMidiDevices() {
  return AlsaSeqLinuxDevice.deviceChangeEvents;
}

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
  FlutterMidiCommandLinux({
    LinuxMidiDeviceDiscovery? deviceDiscovery,
    LinuxMidiDeviceMonitor? deviceMonitor,
    Duration deviceMonitorDebounce = const Duration(milliseconds: 250),
  }) : _deviceDiscovery = deviceDiscovery ?? _discoverLinuxMidiDevices,
       _deviceMonitor = deviceMonitor ?? _monitorLinuxMidiDevices,
       _deviceMonitorDebounce = deviceMonitorDebounce {
    _setupStreamController = StreamController<MidiSetupChange>.broadcast(
      onListen: _startDeviceMonitor,
      onCancel: _stopDeviceMonitorIfIdle,
    );
    _setupStream = _setupStreamController.stream;
    _rxStream = _rxStreamController.stream;
  }

  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  late final Stream<MidiPacket> _rxStream;
  late final StreamController<MidiSetupChange> _setupStreamController;
  late final Stream<MidiSetupChange> _setupStream;

  final Map<String, LinuxMidiDevice> _connectedDevices =
      <String, LinuxMidiDevice>{};
  final LinuxMidiDeviceDiscovery _deviceDiscovery;
  final LinuxMidiDeviceMonitor _deviceMonitor;
  final Duration _deviceMonitorDebounce;
  final Map<String, _LinuxMidiDeviceSnapshot> _knownDeviceSnapshots =
      <String, _LinuxMidiDeviceSnapshot>{};
  StreamSubscription<void>? _deviceMonitorSubscription;
  Timer? _deviceMonitorTimer;
  bool _hasKnownDeviceSnapshot = false;
  bool _tearingDown = false;

  static void registerWith() {
    MidiCommandPlatform.instance = FlutterMidiCommandLinux();
  }

  @override
  Future<List<MidiDevice>> get devices async {
    final portDevices = _deviceDiscovery();
    _rememberDevices(portDevices);

    return portDevices
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
      _addSetupEvent(MidiSetupChange.deviceConnected);
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
      _addSetupEvent(MidiSetupChange.deviceDisconnected);
    }
    unawaited(linuxDevice.disconnect());
  }

  @override
  void teardown() {
    _tearingDown = true;
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = null;
    unawaited(_deviceMonitorSubscription?.cancel());
    _deviceMonitorSubscription = null;

    final connected = _connectedDevices.values.toList(growable: false);
    for (final device in connected) {
      unawaited(device.disconnect());
    }
    _connectedDevices.clear();
    AlsaSeqLinuxDevice.closeSharedContext();
    _addSetupEvent(MidiSetupChange.deviceDisconnected);
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
  Stream<MidiSetupChange>? get onMidiSetupChanged => _setupStream;

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => null;

  @override
  void setNetworkSessionEnabled(bool enabled) {}

  void _addSetupEvent(MidiSetupChange event) {
    if (!_setupStreamController.isClosed) {
      _setupStreamController.add(event);
    }
  }

  void _startDeviceMonitor() {
    if (_tearingDown || _deviceMonitorSubscription != null) {
      return;
    }

    try {
      final portDevices = _deviceDiscovery();
      _rememberDevices(portDevices);
      _deviceMonitorSubscription = _deviceMonitor().listen((_) {
        _scheduleDeviceRefresh();
      });
    } catch (error, stackTrace) {
      if (!_setupStreamController.isClosed) {
        _setupStreamController.addError(error, stackTrace);
      }
    }
  }

  void _stopDeviceMonitorIfIdle() {
    if (_setupStreamController.hasListener) {
      return;
    }
    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = null;
    unawaited(_deviceMonitorSubscription?.cancel());
    _deviceMonitorSubscription = null;
  }

  void _scheduleDeviceRefresh() {
    if (_tearingDown) {
      return;
    }

    _deviceMonitorTimer?.cancel();
    _deviceMonitorTimer = Timer(_deviceMonitorDebounce, () {
      _deviceMonitorTimer = null;
      _refreshDeviceSnapshot();
    });
  }

  void _refreshDeviceSnapshot() {
    if (_tearingDown) {
      return;
    }

    try {
      _applyDeviceSnapshot(_deviceDiscovery());
    } catch (error, stackTrace) {
      if (!_setupStreamController.isClosed) {
        _setupStreamController.addError(error, stackTrace);
      }
    }
  }

  void _rememberDevices(List<LinuxMidiPortDevice> devices) {
    _knownDeviceSnapshots
      ..clear()
      ..addEntries(
        devices.map(
          (device) => MapEntry(device.id, _LinuxMidiDeviceSnapshot(device)),
        ),
      );
    _hasKnownDeviceSnapshot = true;
  }

  void _applyDeviceSnapshot(List<LinuxMidiPortDevice> devices) {
    final nextSnapshots = <String, _LinuxMidiDeviceSnapshot>{
      for (final device in devices) device.id: _LinuxMidiDeviceSnapshot(device),
    };

    if (!_hasKnownDeviceSnapshot) {
      _knownDeviceSnapshots
        ..clear()
        ..addAll(nextSnapshots);
      _hasKnownDeviceSnapshot = true;
      return;
    }

    final previousIds = _knownDeviceSnapshots.keys.toSet();
    final nextIds = nextSnapshots.keys.toSet();
    final disappearedIds = previousIds.difference(nextIds);
    final appearedIds = nextIds.difference(previousIds);
    final retainedIds = previousIds.intersection(nextIds);
    final previousSnapshots = Map<String, _LinuxMidiDeviceSnapshot>.of(
      _knownDeviceSnapshots,
    );
    var stateChanged = false;

    _knownDeviceSnapshots
      ..clear()
      ..addAll(nextSnapshots);

    for (final id in disappearedIds) {
      final disconnectedDevice = _connectedDevices.remove(id);
      if (disconnectedDevice != null) {
        unawaited(disconnectedDevice.disconnect());
      }
      _addSetupEvent(MidiSetupChange.deviceDisappeared);
    }

    for (final id in appearedIds) {
      if (nextSnapshots.containsKey(id)) {
        _addSetupEvent(MidiSetupChange.deviceAppeared);
      }
    }

    for (final id in retainedIds) {
      if (previousSnapshots[id] != nextSnapshots[id]) {
        stateChanged = true;
        break;
      }
    }
    if (stateChanged && disappearedIds.isEmpty && appearedIds.isEmpty) {
      _addSetupEvent(MidiSetupChange.deviceStateChanged);
    }
  }
}

class _LinuxMidiDeviceSnapshot {
  _LinuxMidiDeviceSnapshot(LinuxMidiPortDevice device)
    : id = device.id,
      name = device.name,
      hasInput = device.hasInput,
      hasOutput = device.hasOutput;

  final String id;
  final String name;
  final bool hasInput;
  final bool hasOutput;

  @override
  bool operator ==(Object other) {
    return other is _LinuxMidiDeviceSnapshot &&
        other.id == id &&
        other.name == name &&
        other.hasInput == hasInput &&
        other.hasOutput == hasOutput;
  }

  @override
  int get hashCode => Object.hash(id, name, hasInput, hasOutput);
}
