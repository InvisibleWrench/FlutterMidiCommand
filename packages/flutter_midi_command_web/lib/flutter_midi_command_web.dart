import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'src/web_midi_backend.dart';
import 'src/web_midi_backend_factory.dart';

class FlutterMidiCommandWeb extends MidiCommandPlatform {
  FlutterMidiCommandWeb({WebMidiBackend? backend})
    : _backend = backend ?? createDefaultWebMidiBackend();

  static void registerWith(Registrar registrar) {
    MidiCommandPlatform.instance = FlutterMidiCommandWeb();
  }

  final WebMidiBackend _backend;
  final StreamController<MidiPacket> _rxStreamController =
      StreamController<MidiPacket>.broadcast();
  final StreamController<String> _setupStreamController =
      StreamController<String>.broadcast();

  StreamSubscription<WebMidiStateChange>? _stateChangeSubscription;
  bool _initialized = false;

  final Map<String, _WebDeviceSnapshot> _deviceSnapshots =
      <String, _WebDeviceSnapshot>{};
  final Map<String, MidiDevice> _connectedDeviceRefs = <String, MidiDevice>{};
  final Map<String, List<String>> _connectedInputPortsByDevice =
      <String, List<String>>{};
  final Map<String, List<String>> _connectedOutputPortsByDevice =
      <String, List<String>>{};

  UnsupportedError _unsupported(String message) {
    return UnsupportedError('flutter_midi_command_web: $message');
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    await _backend.initialize();

    _stateChangeSubscription?.cancel();
    _stateChangeSubscription = _backend.onStateChanged.listen((event) {
      switch (event.type) {
        case WebMidiStateChangeType.connected:
          _setupStreamController.add('deviceAppeared');
        case WebMidiStateChangeType.disconnected:
          _setupStreamController.add('deviceDisappeared');
        case WebMidiStateChangeType.changed:
          _setupStreamController.add('deviceStateChanged');
      }
    });

    _initialized = true;
  }

  int _portNumericId(String portId, bool isInput, int fallbackIndex) {
    final parsed = int.tryParse(portId);
    if (parsed != null) {
      return parsed;
    }

    final seed = '$portId|${isInput ? 'in' : 'out'}'.hashCode;
    final normalized = seed & 0x7fffffff;
    if (normalized == 0) {
      return fallbackIndex;
    }
    return normalized;
  }

  String _deviceKeyForPort(WebMidiPortInfo port, {required String fallback}) {
    final manufacturer = (port.manufacturer ?? '').trim();
    final name = (port.name ?? '').trim();

    if (manufacturer.isNotEmpty || name.isNotEmpty) {
      return '$manufacturer::$name';
    }

    if (port.id.isNotEmpty) {
      return port.id;
    }

    return fallback;
  }

  String _displayNameForPort(WebMidiPortInfo port, {required String fallback}) {
    final name = port.name?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return fallback;
  }

  Future<List<_WebDeviceSnapshot>> _snapshotDevices() async {
    await _ensureInitialized();

    final inputs = await _backend.listInputs();
    final outputs = await _backend.listOutputs();
    final grouped = <String, _WebDeviceSnapshotBuilder>{};

    for (var i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final key = _deviceKeyForPort(input, fallback: 'input-$i');
      final builder = grouped.putIfAbsent(
        key,
        () => _WebDeviceSnapshotBuilder(
          id: key,
          name: _displayNameForPort(input, fallback: 'MIDI Input $i'),
        ),
      );

      builder.inputs.add(
        _WebInputPortSnapshot(
          id: _portNumericId(input.id, true, i),
          connected: input.connected,
          portId: input.id,
        ),
      );
    }

    for (var i = 0; i < outputs.length; i++) {
      final output = outputs[i];
      final key = _deviceKeyForPort(output, fallback: 'output-$i');
      final builder = grouped.putIfAbsent(
        key,
        () => _WebDeviceSnapshotBuilder(
          id: key,
          name: _displayNameForPort(output, fallback: 'MIDI Output $i'),
        ),
      );

      builder.outputs.add(
        _WebOutputPortSnapshot(
          id: _portNumericId(output.id, false, i),
          connected: output.connected,
          portId: output.id,
        ),
      );
    }

    final snapshots = grouped.values
        .expand((builder) => builder.buildLogicalDevices())
        .toList(growable: false);

    _deviceSnapshots
      ..clear()
      ..addEntries(
        snapshots.map((snapshot) => MapEntry(snapshot.id, snapshot)),
      );

    return snapshots;
  }

  MidiDevice _toMidiDevice(_WebDeviceSnapshot snapshot) {
    final connected = _connectedDeviceRefs.containsKey(snapshot.id);
    final device =
        _connectedDeviceRefs[snapshot.id] ??
        MidiDevice(
          snapshot.id,
          snapshot.name,
          MidiDeviceType.serial,
          connected,
        );

    device
      ..name = snapshot.name
      ..type = MidiDeviceType.serial
      ..connected = connected
      ..inputPorts = snapshot.inputs
          .map(
            (port) =>
                MidiPort(port.id, MidiPortType.IN)..connected = port.connected,
          )
          .toList(growable: false)
      ..outputPorts = snapshot.outputs
          .map(
            (port) =>
                MidiPort(port.id, MidiPortType.OUT)..connected = port.connected,
          )
          .toList(growable: false);

    return device;
  }

  _WebDeviceSnapshot _requireSnapshot(String deviceId) {
    final snapshot = _deviceSnapshots[deviceId];
    if (snapshot != null) {
      return snapshot;
    }
    throw StateError('Unknown MIDI device: $deviceId');
  }

  List<_WebInputPortSnapshot> _filterInputPorts(
    List<_WebInputPortSnapshot> available,
    List<MidiPort>? selected,
  ) {
    if (selected == null) {
      return available;
    }

    final ids =
        selected
            .where((port) => port.type == MidiPortType.IN)
            .map((port) => port.id)
            .toSet();

    if (ids.isEmpty) {
      return <_WebInputPortSnapshot>[];
    }

    return available.where((port) => ids.contains(port.id)).toList();
  }

  List<_WebOutputPortSnapshot> _filterOutputPorts(
    List<_WebOutputPortSnapshot> available,
    List<MidiPort>? selected,
  ) {
    if (selected == null) {
      return available;
    }

    final ids =
        selected
            .where((port) => port.type == MidiPortType.OUT)
            .map((port) => port.id)
            .toSet();

    if (ids.isEmpty) {
      return <_WebOutputPortSnapshot>[];
    }

    return available.where((port) => ids.contains(port.id)).toList();
  }

  Future<void> _attachInputListener(
    _WebInputPortSnapshot input,
    MidiDevice device,
    String deviceId,
  ) async {
    await _backend.openInput(input.portId, (data, timestamp) {
      final sourceDevice = _connectedDeviceRefs[deviceId] ?? device;
      _rxStreamController.add(
        MidiPacket(Uint8List.fromList(data), timestamp, sourceDevice),
      );
    });
  }

  @override
  Future<List<MidiDevice>?> get devices async {
    final snapshots = await _snapshotDevices();
    return snapshots.map(_toMidiDevice).toList(growable: false);
  }

  @override
  Future<void> connectToDevice(
    MidiDevice device, {
    List<MidiPort>? ports,
  }) async {
    if (!_deviceSnapshots.containsKey(device.id)) {
      await _snapshotDevices();
    }

    final snapshot = _requireSnapshot(device.id);
    final inputPorts = _filterInputPorts(snapshot.inputs, ports);
    final outputPorts = _filterOutputPorts(snapshot.outputs, ports);

    if (inputPorts.isEmpty && outputPorts.isEmpty) {
      throw StateError('Device ${device.id} has no selectable MIDI ports.');
    }

    for (final input in inputPorts) {
      await _attachInputListener(input, device, device.id);
    }

    for (final output in outputPorts) {
      await _backend.openOutput(output.portId);
    }

    _connectedDeviceRefs[device.id] = device;
    _connectedInputPortsByDevice[device.id] = inputPorts
        .map((port) => port.portId)
        .toList(growable: false);
    _connectedOutputPortsByDevice[device.id] = outputPorts
        .map((port) => port.portId)
        .toList(growable: false);

    device.connected = true;
    _setupStreamController.add('deviceConnected');
  }

  @override
  void disconnectDevice(MidiDevice device) {
    unawaited(_disconnectDeviceAsync(device));
  }

  Future<void> _disconnectDeviceAsync(MidiDevice device) async {
    final inputIds = _connectedInputPortsByDevice.remove(device.id) ?? const [];
    final outputIds =
        _connectedOutputPortsByDevice.remove(device.id) ?? const [];

    for (final inputId in inputIds) {
      await _backend.closeInput(inputId);
    }

    for (final outputId in outputIds) {
      await _backend.closeOutput(outputId);
    }

    _connectedDeviceRefs.remove(device.id);
    device.connected = false;
    _setupStreamController.add('deviceDisconnected');
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    final targetOutputIds = <String>[];

    if (deviceId != null) {
      targetOutputIds.addAll(
        _connectedOutputPortsByDevice[deviceId] ?? const [],
      );
    } else {
      for (final outputIds in _connectedOutputPortsByDevice.values) {
        targetOutputIds.addAll(outputIds);
      }
    }

    for (final outputId in targetOutputIds) {
      _backend.send(outputId, data, timestamp: timestamp);
    }
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<String>? get onMidiSetupChanged => _setupStreamController.stream;

  @override
  void addVirtualDevice({String? name}) {
    throw _unsupported('virtual MIDI devices are not supported on web.');
  }

  @override
  void removeVirtualDevice({String? name}) {
    throw _unsupported('virtual MIDI devices are not supported on web.');
  }

  @override
  Future<bool?> get isNetworkSessionEnabled async => false;

  @override
  void setNetworkSessionEnabled(bool enabled) {
    // No-op on web.
  }

  @override
  void teardown() {
    unawaited(_teardownAsync());
  }

  Future<void> _teardownAsync() async {
    final deviceIds = _connectedDeviceRefs.keys.toList(growable: false);
    for (final deviceId in deviceIds) {
      final device = _connectedDeviceRefs[deviceId];
      if (device != null) {
        await _disconnectDeviceAsync(device);
      }
    }

    await _stateChangeSubscription?.cancel();
    _stateChangeSubscription = null;
    _initialized = false;
    _deviceSnapshots.clear();
    _backend.dispose();
  }
}

class _WebInputPortSnapshot {
  _WebInputPortSnapshot({
    required this.id,
    required this.connected,
    required this.portId,
  });

  final int id;
  final bool connected;
  final String portId;
}

class _WebOutputPortSnapshot {
  _WebOutputPortSnapshot({
    required this.id,
    required this.connected,
    required this.portId,
  });

  final int id;
  final bool connected;
  final String portId;
}

class _WebDeviceSnapshot {
  _WebDeviceSnapshot({
    required this.id,
    required this.name,
    required this.inputs,
    required this.outputs,
  });

  final String id;
  final String name;
  final List<_WebInputPortSnapshot> inputs;
  final List<_WebOutputPortSnapshot> outputs;
}

class _WebDeviceSnapshotBuilder {
  _WebDeviceSnapshotBuilder({required this.id, required this.name});

  final String id;
  final String name;
  final List<_WebInputPortSnapshot> inputs = <_WebInputPortSnapshot>[];
  final List<_WebOutputPortSnapshot> outputs = <_WebOutputPortSnapshot>[];

  List<_WebDeviceSnapshot> buildLogicalDevices() {
    inputs.sort((a, b) => a.portId.compareTo(b.portId));
    outputs.sort((a, b) => a.portId.compareTo(b.portId));

    final count =
        inputs.length > outputs.length ? inputs.length : outputs.length;
    if (count == 0) {
      return <_WebDeviceSnapshot>[];
    }

    return List<_WebDeviceSnapshot>.generate(count, (index) {
      final input = index < inputs.length ? inputs[index] : null;
      final output = index < outputs.length ? outputs[index] : null;
      final logicalId =
          '$id|in:${input?.portId ?? ''}|out:${output?.portId ?? ''}';
      final logicalName = count == 1 ? name : '$name [${index + 1}]';

      return _WebDeviceSnapshot(
        id: logicalId,
        name: logicalName,
        inputs:
            input == null
                ? const <_WebInputPortSnapshot>[]
                : List<_WebInputPortSnapshot>.unmodifiable(
                  <_WebInputPortSnapshot>[input],
                ),
        outputs:
            output == null
                ? const <_WebOutputPortSnapshot>[]
                : List<_WebOutputPortSnapshot>.unmodifiable(
                  <_WebOutputPortSnapshot>[output],
                ),
      );
    }, growable: false);
  }
}
