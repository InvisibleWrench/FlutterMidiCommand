import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'web_midi_backend.dart';

class BrowserWebMidiBackend implements WebMidiBackend {
  web.MIDIAccess? _midiAccess;
  final StreamController<WebMidiStateChange> _stateController =
      StreamController<WebMidiStateChange>.broadcast();
  final Map<String, web.MIDIInput> _inputsById = <String, web.MIDIInput>{};
  final Map<String, web.MIDIOutput> _outputsById = <String, web.MIDIOutput>{};
  final Map<String, String> _portStatesById = <String, String>{};
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    final navigatorObject = web.window.navigator as JSObject;
    if (!navigatorObject.has('requestMIDIAccess')) {
      throw UnsupportedError(
        'Web MIDI API is unavailable in this browser. '
        'Use Chrome/Edge over HTTPS and allow MIDI access.',
      );
    }

    final access =
        await web.window.navigator
            .requestMIDIAccess(web.MIDIOptions(sysex: true))
            .toDart;

    _midiAccess = access;
    _initialized = true;
    _bindStateChanges(access);
    _refreshPortCache();
  }

  List<T> _collectValues<T extends JSObject>(JSObject mapLike) {
    final iterator = mapLike.callMethod<JSObject>('values'.toJS);
    final values = <T>[];

    while (true) {
      final next = iterator.callMethod<JSObject>('next'.toJS);
      final done = (next['done'] as JSBoolean?)?.toDart ?? false;
      if (done) {
        break;
      }
      final value = next['value'];
      if (value != null) {
        values.add(value as T);
      }
    }

    return values;
  }

  void _refreshPortCache() {
    final access = _midiAccess;
    if (access == null) {
      return;
    }

    final inputs = _collectValues<web.MIDIInput>(access.inputs as JSObject);
    final outputs = _collectValues<web.MIDIOutput>(access.outputs as JSObject);

    _inputsById
      ..clear()
      ..addEntries(inputs.map((port) => MapEntry(port.id, port)));
    _outputsById
      ..clear()
      ..addEntries(outputs.map((port) => MapEntry(port.id, port)));
    _portStatesById
      ..clear()
      ..addEntries(inputs.map((port) => MapEntry(port.id, port.state)))
      ..addEntries(outputs.map((port) => MapEntry(port.id, port.state)));
  }

  void _bindStateChanges(web.MIDIAccess access) {
    access.onstatechange =
        ((web.Event event) {
          final midiEvent = event as web.MIDIConnectionEvent;
          final portId = midiEvent.port?.id;
          final state = midiEvent.port?.state;
          final previousState = portId == null ? null : _portStatesById[portId];
          _refreshPortCache();

          if (portId != null && state != null && previousState == state) {
            return;
          }

          final type = switch (state) {
            'connected' => WebMidiStateChangeType.connected,
            'disconnected' => WebMidiStateChangeType.disconnected,
            _ => WebMidiStateChangeType.changed,
          };

          _stateController.add(
            WebMidiStateChange(type: type, portId: midiEvent.port?.id),
          );
        }).toJS;
  }

  web.MIDIInput _requireInput(String portId) {
    final port = _inputsById[portId];
    if (port != null) {
      return port;
    }
    throw StateError('Unknown MIDI input port: $portId');
  }

  web.MIDIOutput _requireOutput(String portId) {
    final port = _outputsById[portId];
    if (port != null) {
      return port;
    }
    throw StateError('Unknown MIDI output port: $portId');
  }

  @override
  Stream<WebMidiStateChange> get onStateChanged => _stateController.stream;

  @override
  Future<List<WebMidiPortInfo>> listInputs() async {
    await initialize();
    _refreshPortCache();

    return _inputsById.values
        .map(
          (port) => WebMidiPortInfo(
            id: port.id,
            name: port.name,
            manufacturer: port.manufacturer,
            connected: port.state == 'connected',
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<WebMidiPortInfo>> listOutputs() async {
    await initialize();
    _refreshPortCache();

    return _outputsById.values
        .map(
          (port) => WebMidiPortInfo(
            id: port.id,
            name: port.name,
            manufacturer: port.manufacturer,
            connected: port.state == 'connected',
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> openInput(
    String portId,
    WebMidiMessageCallback onMessage,
  ) async {
    await initialize();
    _refreshPortCache();
    final input = _requireInput(portId);

    await input.open().toDart;
    input.onmidimessage =
        ((web.Event event) {
          final midiEvent = event as web.MIDIMessageEvent;
          final data = midiEvent.data?.toDart ?? Uint8List(0);
          onMessage(Uint8List.fromList(data), event.timeStamp.toInt());
        }).toJS;
  }

  @override
  Future<void> closeInput(String portId) async {
    await initialize();
    _refreshPortCache();
    final input = _inputsById[portId];
    if (input == null) {
      return;
    }

    input.onmidimessage = null;
    await input.close().toDart;
  }

  @override
  Future<void> openOutput(String portId) async {
    await initialize();
    _refreshPortCache();
    final output = _requireOutput(portId);
    await output.open().toDart;
  }

  @override
  Future<void> closeOutput(String portId) async {
    await initialize();
    _refreshPortCache();
    final output = _outputsById[portId];
    if (output == null) {
      return;
    }
    await output.close().toDart;
  }

  @override
  void send(String outputPortId, Uint8List data, {int? timestamp}) {
    final output = _outputsById[outputPortId];
    if (output == null) {
      return;
    }

    final payload = data.map((byte) => byte.toJS).toList(growable: false).toJS;
    if (timestamp != null) {
      output.send(payload, timestamp.toDouble());
    } else {
      output.send(payload);
    }
  }

  @override
  void dispose() {
    _midiAccess?.onstatechange = null;
    _midiAccess = null;
    _initialized = false;
    _inputsById.clear();
    _outputsById.clear();
    _portStatesById.clear();
  }
}
