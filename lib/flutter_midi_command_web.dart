import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:flutter_midi_command_platform_interface/flutter_midi_command_platform_interface.dart';
import 'package:web/web.dart' as web;

@JS('Array.from')
external JSArray _jsArrayFrom(JSObject obj);

class FlutterMidiCommandWeb extends MidiCommandPlatform {
  static void registerWith(Registrar registrar) {
    MidiCommandPlatform.instance = FlutterMidiCommandWeb();
  }

  web.MIDIAccess? _midiAccess;
  final _rxStreamController = StreamController<MidiPacket>.broadcast();
  final _setupStreamController = StreamController<String>.broadcast();
  final _bluetoothStateStreamController = StreamController<String>.broadcast();

  Future<void> _initMidi() async {
    if (_midiAccess != null) return;
    try {
      final promise = web.window.navigator.requestMIDIAccess(web.MIDIOptions(sysex: true));
      _midiAccess = await promise.toDart;
      
      _midiAccess?.onstatechange = (web.Event event) {
        _setupStreamController.add("deviceFound");
      }.toJS;
    } catch (e) {
      print("Failed to initialize Web MIDI: $e");
    }
  }

  List<T> _getMapValues<T extends JSObject>(JSObject mapObject) {
    final valuesIterator = mapObject.callMethod('values'.toJS);
    if (valuesIterator == null) return [];
    final jsArray = _jsArrayFrom(valuesIterator as JSObject);
    
    final list = <T>[];
    for (int i = 0; i < jsArray.length; i++) {
      final item = jsArray.getProperty(i.toJS);
      if (item != null) {
        list.add(item as T);
      }
    }
    return list;
  }

  @override
  Future<List<MidiDevice>?> get devices async {
    await _initMidi();
    final access = _midiAccess;
    if (access == null) return [];

    final list = <MidiDevice>[];

    // Read inputs
    final inputs = _getMapValues<web.MIDIInput>(access.inputs);
    for (final input in inputs) {
      final device = MidiDevice(
        input.id,
        input.name ?? 'Unknown Input',
        'web',
        input.connection == 'open',
      );
      device.inputPorts.add(MidiPort(0, MidiPortType.IN));
      list.add(device);
    }

    // Read outputs
    final outputs = _getMapValues<web.MIDIOutput>(access.outputs);
    for (final output in outputs) {
      final device = MidiDevice(
        output.id,
        output.name ?? 'Unknown Output',
        'web',
        output.connection == 'open',
      );
      device.outputPorts.add(MidiPort(0, MidiPortType.OUT));
      list.add(device);
    }

    return list;
  }

  @override
  Future<void> connectToDevice(MidiDevice device, {List<MidiPort>? ports}) async {
    await _initMidi();
    final access = _midiAccess;
    if (access == null) return;

    // Search in inputs
    final inputs = _getMapValues<web.MIDIInput>(access.inputs);
    final input = inputs.where((i) => i.id == device.id).firstOrNull;
    if (input != null) {
      await input.open().toDart;
      
      input.onmidimessage = (web.Event event) {
        final messageEvent = event as web.MIDIMessageEvent;
        final jsData = messageEvent.data;
        if (jsData != null) {
          final dartData = jsData.toDart;
          final activeDevice = MidiDevice(device.id, device.name, device.type, true);
          activeDevice.inputPorts.add(MidiPort(0, MidiPortType.IN));
          _rxStreamController.add(MidiPacket(
            dartData,
            messageEvent.timeStamp.toInt(),
            activeDevice,
          ));
        }
      }.toJS;
      
      device.connected = true;
      _setupStreamController.add("deviceConnected");
      return;
    }

    // Search in outputs
    final outputs = _getMapValues<web.MIDIOutput>(access.outputs);
    final output = outputs.where((o) => o.id == device.id).firstOrNull;
    if (output != null) {
      await output.open().toDart;
      device.connected = true;
      _setupStreamController.add("deviceConnected");
      return;
    }
  }

  @override
  void disconnectDevice(MidiDevice device) {
    final access = _midiAccess;
    if (access == null) return;

    final inputs = _getMapValues<web.MIDIInput>(access.inputs);
    final input = inputs.where((i) => i.id == device.id).firstOrNull;
    if (input != null) {
      input.onmidimessage = null;
      input.close();
      device.connected = false;
      _setupStreamController.add("deviceDisconnected");
      return;
    }

    final outputs = _getMapValues<web.MIDIOutput>(access.outputs);
    final output = outputs.where((o) => o.id == device.id).firstOrNull;
    if (output != null) {
      output.close();
      device.connected = false;
      _setupStreamController.add("deviceDisconnected");
      return;
    }
  }

  @override
  void sendData(Uint8List data, {int? timestamp, String? deviceId}) {
    final access = _midiAccess;
    if (access == null) return;

    final outputs = _getMapValues<web.MIDIOutput>(access.outputs);
    final JSArray<JSNumber> jsData = data.map((b) => b.toJS).toList().toJS;

    if (deviceId != null) {
      final output = outputs.where((o) => o.id == deviceId).firstOrNull;
      if (output != null && output.connection == 'open') {
        output.send(jsData);
      }
    } else {
      for (final output in outputs) {
        if (output.connection == 'open') {
          output.send(jsData);
        }
      }
    }
  }

  @override
  void teardown() {
    final access = _midiAccess;
    if (access == null) return;

    final inputs = _getMapValues<web.MIDIInput>(access.inputs);
    for (final input in inputs) {
      input.onmidimessage = null;
      input.close();
    }

    final outputs = _getMapValues<web.MIDIOutput>(access.outputs);
    for (final output in outputs) {
      output.close();
    }
  }

  @override
  Stream<MidiPacket>? get onMidiDataReceived => _rxStreamController.stream;

  @override
  Stream<String>? get onMidiSetupChanged => _setupStreamController.stream;

  @override
  Stream<String>? get onBluetoothStateChanged => _bluetoothStateStreamController.stream;

  @override
  Future<void> startBluetoothCentral() async {
    _bluetoothStateStreamController.add("unsupported");
  }

  @override
  Future<String> bluetoothState() async => "unsupported";

  @override
  Future<void> startScanningForBluetoothDevices() async {}

  @override
  void stopScanningForBluetoothDevices() {}

  @override
  void addVirtualDevice({String? name}) {}

  @override
  void removeVirtualDevice({String? name}) {}

  @override
  Future<bool?> get isNetworkSessionEnabled async => false;

  @override
  void setNetworkSessionEnabled(bool enabled) {}
}
