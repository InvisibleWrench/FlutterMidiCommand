import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:flutter_midi_command_web/flutter_midi_command_web.dart';
import 'package:flutter_midi_command_web/src/web_midi_backend.dart';
import 'package:flutter_test/flutter_test.dart';

const _stateChangeDebounceWait = Duration(milliseconds: 300);

class _SendCall {
  _SendCall(this.outputPortId, this.data, this.timestamp);

  final String outputPortId;
  final Uint8List data;
  final int? timestamp;
}

class _FakeWebMidiBackend implements WebMidiBackend {
  _FakeWebMidiBackend({
    required List<WebMidiPortInfo> inputs,
    required List<WebMidiPortInfo> outputs,
    this.initializeError,
  }) : _inputs = Map<String, WebMidiPortInfo>.fromEntries(
         inputs.map((port) => MapEntry(port.id, port)),
       ),
       _outputs = Map<String, WebMidiPortInfo>.fromEntries(
         outputs.map((port) => MapEntry(port.id, port)),
       );

  final Object? initializeError;

  final Map<String, WebMidiPortInfo> _inputs;
  final Map<String, WebMidiPortInfo> _outputs;
  final StreamController<WebMidiStateChange> _stateController =
      StreamController<WebMidiStateChange>.broadcast();
  final Map<String, WebMidiMessageCallback> _inputCallbacks =
      <String, WebMidiMessageCallback>{};

  final List<String> openedInputs = <String>[];
  final List<String> openedOutputs = <String>[];
  final List<String> closedInputs = <String>[];
  final List<String> closedOutputs = <String>[];
  final List<_SendCall> sendCalls = <_SendCall>[];

  bool initialized = false;
  int disposeCalls = 0;

  @override
  Future<void> initialize() async {
    if (initializeError != null) {
      throw initializeError!;
    }
    initialized = true;
  }

  @override
  Stream<WebMidiStateChange> get onStateChanged => _stateController.stream;

  @override
  Future<List<WebMidiPortInfo>> listInputs() async =>
      _inputs.values.toList(growable: false);

  @override
  Future<List<WebMidiPortInfo>> listOutputs() async =>
      _outputs.values.toList(growable: false);

  @override
  Future<void> openInput(
    String portId,
    WebMidiMessageCallback onMessage,
  ) async {
    if (!_inputs.containsKey(portId)) {
      throw StateError('Unknown input: $portId');
    }
    openedInputs.add(portId);
    _inputCallbacks[portId] = onMessage;
  }

  @override
  Future<void> closeInput(String portId) async {
    closedInputs.add(portId);
    _inputCallbacks.remove(portId);
  }

  @override
  Future<void> openOutput(String portId) async {
    if (!_outputs.containsKey(portId)) {
      throw StateError('Unknown output: $portId');
    }
    openedOutputs.add(portId);
  }

  @override
  Future<void> closeOutput(String portId) async {
    closedOutputs.add(portId);
  }

  @override
  void send(String outputPortId, Uint8List data, {int? timestamp}) {
    sendCalls.add(_SendCall(outputPortId, data, timestamp));
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }

  void emitStateChange(WebMidiStateChangeType type, {String? portId}) {
    _stateController.add(WebMidiStateChange(type: type, portId: portId));
  }

  void addInput(WebMidiPortInfo port) {
    _inputs[port.id] = port;
  }

  void updateInput(WebMidiPortInfo port) {
    _inputs[port.id] = port;
  }

  void removeInput(String portId) {
    _inputs.remove(portId);
  }

  void addOutput(WebMidiPortInfo port) {
    _outputs[port.id] = port;
  }

  void removeOutput(String portId) {
    _outputs.remove(portId);
  }

  void emitMessage(String inputPortId, Uint8List data, int timestamp) {
    final callback = _inputCallbacks[inputPortId];
    if (callback != null) {
      callback(data, timestamp);
    }
  }
}

WebMidiPortInfo _port(
  String id, {
  required String name,
  required String manufacturer,
  bool connected = true,
}) {
  return WebMidiPortInfo(
    id: id,
    name: name,
    manufacturer: manufacturer,
    connected: connected,
  );
}

void main() {
  test('devices are mapped as serial MidiDevice with ports', () async {
    final backend = _FakeWebMidiBackend(
      inputs: <WebMidiPortInfo>[_port('1', name: 'Keys', manufacturer: 'Acme')],
      outputs: <WebMidiPortInfo>[
        _port('11', name: 'Keys', manufacturer: 'Acme'),
      ],
    );

    final plugin = FlutterMidiCommandWeb(backend: backend);
    final devices = await plugin.devices;

    expect(backend.initialized, isTrue);
    expect(devices, isNotNull);
    expect(devices!.length, 1);
    expect(devices.first.type, MidiDeviceType.serial);
    expect(devices.first.inputPorts.length, 1);
    expect(devices.first.outputPorts.length, 1);
    expect(devices.first.inputPorts.first.id, 1);
    expect(devices.first.outputPorts.first.id, 11);
  });

  test(
    'same-name multi-port devices are exposed as separate devices',
    () async {
      final backend = _FakeWebMidiBackend(
        inputs: <WebMidiPortInfo>[
          _port('2', name: 'Interface', manufacturer: 'Acme'),
          _port('1', name: 'Interface', manufacturer: 'Acme'),
        ],
        outputs: <WebMidiPortInfo>[
          _port('12', name: 'Interface', manufacturer: 'Acme'),
          _port('11', name: 'Interface', manufacturer: 'Acme'),
        ],
      );

      final plugin = FlutterMidiCommandWeb(backend: backend);
      final devices = await plugin.devices;

      expect(devices, isNotNull);
      expect(devices!.length, 2);
      expect(devices.map((device) => device.name), <String>[
        'Interface [1]',
        'Interface [2]',
      ]);
      expect(devices.map((device) => device.inputPorts.single.id), <int>[1, 2]);
      expect(devices.map((device) => device.outputPorts.single.id), <int>[
        11,
        12,
      ]);
    },
  );

  test('unbalanced same-name ports remain individually addressable', () async {
    final backend = _FakeWebMidiBackend(
      inputs: <WebMidiPortInfo>[
        _port('1', name: 'Interface', manufacturer: 'Acme'),
        _port('2', name: 'Interface', manufacturer: 'Acme'),
      ],
      outputs: <WebMidiPortInfo>[
        _port('11', name: 'Interface', manufacturer: 'Acme'),
      ],
    );

    final plugin = FlutterMidiCommandWeb(backend: backend);
    final devices = await plugin.devices;

    expect(devices, isNotNull);
    expect(devices!.length, 2);
    expect(devices[0].inputPorts.single.id, 1);
    expect(devices[0].outputPorts.single.id, 11);
    expect(devices[1].inputPorts.single.id, 2);
    expect(devices[1].outputPorts, isEmpty);
  });

  test('state changes are emitted as setup events', () async {
    final backend = _FakeWebMidiBackend(inputs: const [], outputs: const []);
    final plugin = FlutterMidiCommandWeb(backend: backend);

    final events = <MidiSetupChange>[];
    final sub = plugin.onMidiSetupChanged!.listen(events.add);

    await Future<void>.delayed(const Duration(milliseconds: 1));
    backend.addInput(_port('1', name: 'Keys', manufacturer: 'Acme'));
    backend.emitStateChange(WebMidiStateChangeType.connected, portId: '1');
    await Future<void>.delayed(_stateChangeDebounceWait);
    backend.updateInput(
      _port('1', name: 'Keys', manufacturer: 'Acme', connected: false),
    );
    backend.emitStateChange(WebMidiStateChangeType.changed, portId: '1');
    await Future<void>.delayed(_stateChangeDebounceWait);
    backend.removeInput('1');
    backend.emitStateChange(WebMidiStateChangeType.disconnected, portId: '1');

    await Future<void>.delayed(_stateChangeDebounceWait);
    await sub.cancel();

    expect(
      events,
      containsAll(<MidiSetupChange>[
        MidiSetupChange.deviceAppeared,
        MidiSetupChange.deviceDisappeared,
        MidiSetupChange.deviceStateChanged,
      ]),
    );
  });

  test(
    'disappearing connected device closes ports and removes routing',
    () async {
      final backend = _FakeWebMidiBackend(
        inputs: <WebMidiPortInfo>[
          _port('1', name: 'Synth', manufacturer: 'Acme'),
        ],
        outputs: <WebMidiPortInfo>[
          _port('11', name: 'Synth', manufacturer: 'Acme'),
        ],
      );
      final plugin = FlutterMidiCommandWeb(backend: backend);
      final device = (await plugin.devices)!.single;
      final events = <MidiSetupChange>[];
      final sub = plugin.onMidiSetupChanged!.listen(events.add);

      await plugin.connectToDevice(device);
      backend
        ..removeInput('1')
        ..removeOutput('11');
      backend.emitStateChange(WebMidiStateChangeType.disconnected, portId: '1');
      await Future<void>.delayed(_stateChangeDebounceWait);

      backend.emitMessage('1', Uint8List.fromList(<int>[0x90]), 1);
      plugin.sendData(Uint8List.fromList(<int>[0x80]), deviceId: device.id);

      expect(device.connected, isFalse);
      expect(backend.closedInputs, <String>['1']);
      expect(backend.closedOutputs, <String>['11']);
      expect(backend.sendCalls, isEmpty);
      expect(events, contains(MidiSetupChange.deviceDisappeared));

      await sub.cancel();
    },
  );

  test(
    'connect selects requested ports, receives data and sends to selected output',
    () async {
      final backend = _FakeWebMidiBackend(
        inputs: <WebMidiPortInfo>[
          _port('1', name: 'Synth', manufacturer: 'Acme'),
          _port('2', name: 'Synth', manufacturer: 'Acme'),
        ],
        outputs: <WebMidiPortInfo>[
          _port('11', name: 'Synth', manufacturer: 'Acme'),
          _port('12', name: 'Synth', manufacturer: 'Acme'),
        ],
      );

      final plugin = FlutterMidiCommandWeb(backend: backend);
      final devices = (await plugin.devices)!;
      final device = devices.singleWhere(
        (device) =>
            device.inputPorts.single.id == 1 &&
            device.outputPorts.single.id == 11,
      );

      final selectedInput = device.inputPorts.firstWhere(
        (port) => port.id == 1,
      );
      final selectedOutput = device.outputPorts.single;

      await plugin.connectToDevice(
        device,
        ports: <MidiPort>[selectedInput, selectedOutput],
      );

      expect(device.connected, isTrue);
      expect(backend.openedInputs, <String>['1']);
      expect(backend.openedOutputs, <String>['11']);

      final packets = <MidiPacket>[];
      final sub = plugin.onMidiDataReceived!.listen(packets.add);

      backend.emitMessage('2', Uint8List.fromList(<int>[0x90]), 1);
      backend.emitMessage('1', Uint8List.fromList(<int>[0x90, 0x3C, 0x64]), 42);

      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(packets.length, 1);
      expect(packets.first.timestamp, 42);
      expect(packets.first.device.id, device.id);
      expect(packets.first.data, Uint8List.fromList(<int>[0x90, 0x3C, 0x64]));

      plugin.sendData(
        Uint8List.fromList(<int>[0x80, 0x3C, 0x00]),
        deviceId: device.id,
        timestamp: 99,
      );

      expect(backend.sendCalls.length, 1);
      expect(backend.sendCalls.first.outputPortId, '11');
      expect(backend.sendCalls.first.timestamp, 99);

      await sub.cancel();
    },
  );

  test(
    'disconnect closes connected ports and marks device disconnected',
    () async {
      final backend = _FakeWebMidiBackend(
        inputs: <WebMidiPortInfo>[
          _port('1', name: 'Synth', manufacturer: 'Acme'),
        ],
        outputs: <WebMidiPortInfo>[
          _port('11', name: 'Synth', manufacturer: 'Acme'),
        ],
      );

      final plugin = FlutterMidiCommandWeb(backend: backend);
      final device = (await plugin.devices)!.single;

      await plugin.connectToDevice(device);
      plugin.disconnectDevice(device);
      await Future<void>.delayed(const Duration(milliseconds: 1));

      expect(device.connected, isFalse);
      expect(backend.closedInputs, <String>['1']);
      expect(backend.closedOutputs, <String>['11']);
    },
  );

  test('teardown disposes backend and disconnects active devices', () async {
    final backend = _FakeWebMidiBackend(
      inputs: <WebMidiPortInfo>[
        _port('1', name: 'Synth A', manufacturer: 'Acme'),
      ],
      outputs: <WebMidiPortInfo>[
        _port('11', name: 'Synth A', manufacturer: 'Acme'),
      ],
    );

    final plugin = FlutterMidiCommandWeb(backend: backend);
    final device = (await plugin.devices)!.single;

    await plugin.connectToDevice(device);
    plugin.teardown();
    await Future<void>.delayed(const Duration(milliseconds: 1));

    expect(backend.disposeCalls, 1);
    expect(backend.closedInputs, <String>['1']);
    expect(backend.closedOutputs, <String>['11']);
  });

  test('connectToDevice throws when no selected ports match', () async {
    final backend = _FakeWebMidiBackend(
      inputs: <WebMidiPortInfo>[
        _port('1', name: 'Synth', manufacturer: 'Acme'),
      ],
      outputs: <WebMidiPortInfo>[
        _port('11', name: 'Synth', manufacturer: 'Acme'),
      ],
    );

    final plugin = FlutterMidiCommandWeb(backend: backend);
    final device = (await plugin.devices)!.single;

    await expectLater(
      plugin.connectToDevice(
        device,
        ports: <MidiPort>[MidiPort(999, MidiPortType.IN)],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('unsupported backend surfaces initialization errors', () async {
    final backend = _FakeWebMidiBackend(
      inputs: const <WebMidiPortInfo>[],
      outputs: const <WebMidiPortInfo>[],
      initializeError: UnsupportedError('Web MIDI unavailable'),
    );

    final plugin = FlutterMidiCommandWeb(backend: backend);

    await expectLater(plugin.devices, throwsA(isA<UnsupportedError>()));
  });
}
