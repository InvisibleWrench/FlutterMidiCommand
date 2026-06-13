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
  final StreamController<MidiSetupChange> _setupStreamController =
      StreamController<MidiSetupChange>.broadcast();

  StreamSubscription<WebMidiStateChange>? _stateChangeSubscription;
  Timer? _stateChangeTimer;
  Map<String, _WebDeviceSnapshot>? _stateChangeBaseSnapshots;
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
      _scheduleStateChangeRefresh();
    });

    _initialized = true;
  }

  void _scheduleStateChangeRefresh() {
    _stateChangeBaseSnapshots ??= Map<String, _WebDeviceSnapshot>.of(
      _deviceSnapshots,
    );
    _stateChangeTimer?.cancel();
    _stateChangeTimer = Timer(const Duration(milliseconds: 250), () {
      _stateChangeTimer = null;
      final previousSnapshots =
          _stateChangeBaseSnapshots ??
          Map<String, _WebDeviceSnapshot>.of(_deviceSnapshots);
      _stateChangeBaseSnapshots = null;
      unawaited(_refreshStateChange(previousSnapshots));
    });
  }

  Future<void> _refreshStateChange(
    Map<String, _WebDeviceSnapshot> previousSnapshots,
  ) async {
    final nextSnapshots = await _snapshotDevices();
    _emitSnapshotChanges(previousSnapshots, nextSnapshots);
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

  String _normalizedDeviceKeyForPort(
    WebMidiPortInfo port, {
    required String fallback,
  }) {
    final name =
        normalizeWebMidiEndpointName(
          port.name ?? fallback,
        ).trim().toLowerCase();

    if (name.isNotEmpty) {
      return name;
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
          port: input,
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
          port: output,
        ),
      );
    }

    final snapshots = buildWebMidiDevices(
      grouped.values
          .expand((builder) => builder.inputs)
          .toList(growable: false),
      grouped.values
          .expand((builder) => builder.outputs)
          .toList(growable: false),
      normalizedGroupKeyForInput:
          (input) =>
              _normalizedDeviceKeyForPort(input.port, fallback: input.portId),
      normalizedGroupKeyForOutput:
          (output) =>
              _normalizedDeviceKeyForPort(output.port, fallback: output.portId),
    );

    _deviceSnapshots
      ..clear()
      ..addEntries(
        snapshots.map((snapshot) => MapEntry(snapshot.id, snapshot)),
      );

    return snapshots;
  }

  void _emitSnapshotChanges(
    Map<String, _WebDeviceSnapshot> previousSnapshots,
    List<_WebDeviceSnapshot> nextSnapshots,
  ) {
    final nextSnapshotMap = <String, _WebDeviceSnapshot>{
      for (final snapshot in nextSnapshots) snapshot.id: snapshot,
    };
    final previousIds = previousSnapshots.keys.toSet();
    final nextIds = nextSnapshotMap.keys.toSet();
    final disappearedIds = previousIds.difference(nextIds);
    final appearedIds = nextIds.difference(previousIds);
    final retainedIds = previousIds.intersection(nextIds);
    var stateChanged = false;

    for (final id in disappearedIds) {
      final connectedDevice = _connectedDeviceRefs[id];
      if (connectedDevice != null) {
        unawaited(_disconnectDeviceAsync(connectedDevice, emitSetup: false));
      }
      _setupStreamController.add(MidiSetupChange.deviceDisappeared);
    }

    for (final _ in appearedIds) {
      _setupStreamController.add(MidiSetupChange.deviceAppeared);
    }

    for (final id in retainedIds) {
      if (!_snapshotsEqual(previousSnapshots[id], nextSnapshotMap[id])) {
        stateChanged = true;
        break;
      }
    }
    if (stateChanged && appearedIds.isEmpty && disappearedIds.isEmpty) {
      _setupStreamController.add(MidiSetupChange.deviceStateChanged);
    }
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
    _setupStreamController.add(MidiSetupChange.deviceConnected);
  }

  @override
  void disconnectDevice(MidiDevice device) {
    unawaited(_disconnectDeviceAsync(device));
  }

  Future<void> _disconnectDeviceAsync(
    MidiDevice device, {
    bool emitSetup = true,
  }) async {
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
    if (emitSetup) {
      _setupStreamController.add(MidiSetupChange.deviceDisconnected);
    }
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
  Stream<MidiSetupChange>? get onMidiSetupChanged {
    unawaited(_snapshotDevices());
    return _setupStreamController.stream;
  }

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
    _stateChangeTimer?.cancel();
    _stateChangeTimer = null;
    _stateChangeBaseSnapshots = null;
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
    required this.port,
  });

  final int id;
  final bool connected;
  final String portId;
  final WebMidiPortInfo port;
}

class _WebOutputPortSnapshot {
  _WebOutputPortSnapshot({
    required this.id,
    required this.connected,
    required this.portId,
    required this.port,
  });

  final int id;
  final bool connected;
  final String portId;
  final WebMidiPortInfo port;
}

bool _snapshotsEqual(_WebDeviceSnapshot? a, _WebDeviceSnapshot? b) {
  if (a == null || b == null) {
    return a == b;
  }
  return a.id == b.id &&
      a.name == b.name &&
      _inputSnapshotsEqual(a.inputs, b.inputs) &&
      _outputSnapshotsEqual(a.outputs, b.outputs);
}

bool _inputSnapshotsEqual(
  List<_WebInputPortSnapshot> a,
  List<_WebInputPortSnapshot> b,
) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].connected != b[i].connected ||
        a[i].portId != b[i].portId) {
      return false;
    }
  }
  return true;
}

bool _outputSnapshotsEqual(
  List<_WebOutputPortSnapshot> a,
  List<_WebOutputPortSnapshot> b,
) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].connected != b[i].connected ||
        a[i].portId != b[i].portId) {
      return false;
    }
  }
  return true;
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
}

List<_WebDeviceSnapshot> buildWebMidiDevices(
  List<_WebInputPortSnapshot> inputs,
  List<_WebOutputPortSnapshot> outputs, {
  required String Function(_WebInputPortSnapshot input)
  normalizedGroupKeyForInput,
  required String Function(_WebOutputPortSnapshot output)
  normalizedGroupKeyForOutput,
}) {
  final devices = <_WebDeviceSnapshot>[];
  final allocatedNames = <String, int>{};
  final pairedInputIds = <String>{};
  final pairedOutputIds = <String>{};

  void addDevice({
    required String baseName,
    _WebInputPortSnapshot? input,
    _WebOutputPortSnapshot? output,
  }) {
    final trimmedBaseName = baseName.trim();
    final resolvedName =
        trimmedBaseName.isEmpty
            ? 'MIDI Device'
            : normalizeWebMidiEndpointName(trimmedBaseName);
    final allocatedCount = allocatedNames[resolvedName] ?? 0;
    allocatedNames[resolvedName] = allocatedCount + 1;
    final deviceLabel =
        allocatedCount == 0
            ? resolvedName
            : '$resolvedName [${allocatedCount + 1}]';
    final logicalId =
        '${resolvedName.toLowerCase()}|in:${input?.portId ?? ''}|out:${output?.portId ?? ''}';

    if (input != null) {
      pairedInputIds.add(input.portId);
    }
    if (output != null) {
      pairedOutputIds.add(output.portId);
    }

    devices.add(
      _WebDeviceSnapshot(
        id: logicalId,
        name: deviceLabel,
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
      ),
    );
  }

  final inputsByName = _groupEndpointsByKey(inputs, (input) => input.port.name);
  final outputsByName = _groupEndpointsByKey(
    outputs,
    (output) => output.port.name,
  );
  final orderedExactNames = _orderedSharedKeys(
    inputs.map((input) => input.port.name),
    outputs.map((output) => output.port.name),
  );

  for (final name in orderedExactNames) {
    if (name == null) {
      continue;
    }
    final inputEndpoints = List<_WebInputPortSnapshot>.of(
      inputsByName[name] ?? const <_WebInputPortSnapshot>[],
    )..sort((a, b) => a.portId.compareTo(b.portId));
    final outputEndpoints = List<_WebOutputPortSnapshot>.of(
      outputsByName[name] ?? const <_WebOutputPortSnapshot>[],
    )..sort((a, b) => a.portId.compareTo(b.portId));
    final pairCount =
        inputEndpoints.length < outputEndpoints.length
            ? inputEndpoints.length
            : outputEndpoints.length;

    for (var index = 0; index < pairCount; index++) {
      addDevice(
        baseName: name,
        input: inputEndpoints[index],
        output: outputEndpoints[index],
      );
    }
  }

  final remainingInputs = inputs
      .where((input) => !pairedInputIds.contains(input.portId))
      .toList(growable: false);
  final remainingOutputs = outputs
      .where((output) => !pairedOutputIds.contains(output.portId))
      .toList(growable: false);
  final inputsByGroup = _groupEndpointsByKey(
    remainingInputs,
    normalizedGroupKeyForInput,
  );
  final outputsByGroup = _groupEndpointsByKey(
    remainingOutputs,
    normalizedGroupKeyForOutput,
  );
  final orderedNormalizedGroups = _orderedSharedKeys(
    remainingInputs.map(normalizedGroupKeyForInput),
    remainingOutputs.map(normalizedGroupKeyForOutput),
  );

  for (final groupKey in orderedNormalizedGroups) {
    final inputEndpoints = List<_WebInputPortSnapshot>.of(
      inputsByGroup[groupKey] ?? const <_WebInputPortSnapshot>[],
    )..sort((a, b) => a.portId.compareTo(b.portId));
    final outputEndpoints = List<_WebOutputPortSnapshot>.of(
      outputsByGroup[groupKey] ?? const <_WebOutputPortSnapshot>[],
    )..sort((a, b) => a.portId.compareTo(b.portId));
    if (inputEndpoints.isEmpty ||
        outputEndpoints.isEmpty ||
        inputEndpoints.length != outputEndpoints.length) {
      continue;
    }

    for (var index = 0; index < inputEndpoints.length; index++) {
      addDevice(
        baseName: inputEndpoints[index].port.name ?? 'MIDI Device',
        input: inputEndpoints[index],
        output: outputEndpoints[index],
      );
    }
  }

  for (final input in inputs) {
    if (!pairedInputIds.contains(input.portId)) {
      addDevice(baseName: input.port.name ?? 'MIDI Input', input: input);
    }
  }

  for (final output in outputs) {
    if (!pairedOutputIds.contains(output.portId)) {
      addDevice(baseName: output.port.name ?? 'MIDI Output', output: output);
    }
  }

  return devices;
}

String normalizeWebMidiEndpointName(String name) {
  var normalized = name.trim().replaceAll(RegExp(r'\s+'), ' ');

  final bracketedDirectionPrefix = RegExp(
    r'^(midi\s*in|midi\s*out|midiin|midiout)\d*\s*\((.+)\)$',
    caseSensitive: false,
  );
  final bracketedMatch = bracketedDirectionPrefix.firstMatch(normalized);
  if (bracketedMatch != null) {
    normalized = bracketedMatch.group(2)!;
  }

  normalized = normalized.replaceFirst(
    RegExp(
      r'^(midi\s*in|midi\s*out|midiin|midiout)\d*\s*[:\-]?\s*',
      caseSensitive: false,
    ),
    '',
  );
  normalized = normalized.replaceFirst(
    RegExp(r'^(input|output)\s*[:\-]?\s*', caseSensitive: false),
    '',
  );
  normalized = normalized.replaceFirst(
    RegExp(r'\s+\((input|output)\)$', caseSensitive: false),
    '',
  );
  normalized = normalized.trim();
  return normalized.isEmpty ? name.trim() : normalized;
}

Map<K, List<T>> _groupEndpointsByKey<T, K>(
  List<T> endpoints,
  K Function(T endpoint) keySelector,
) {
  final grouped = <K, List<T>>{};
  for (final endpoint in endpoints) {
    grouped.putIfAbsent(keySelector(endpoint), () => <T>[]).add(endpoint);
  }
  return grouped;
}

List<T> _orderedSharedKeys<T>(Iterable<T> first, Iterable<T> second) {
  final firstKeys = first.toSet();
  final secondKeys = second.toSet();
  final orderedKeys = <T>[];
  final seenKeys = <T>{};

  for (final key in first) {
    if (secondKeys.contains(key) && seenKeys.add(key)) {
      orderedKeys.add(key);
    }
  }
  for (final key in second) {
    if (firstKeys.contains(key) && seenKeys.add(key)) {
      orderedKeys.add(key);
    }
  }

  return orderedKeys;
}
