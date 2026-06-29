import 'dart:typed_data';

class WebMidiPortInfo {
  const WebMidiPortInfo({
    required this.id,
    required this.name,
    required this.manufacturer,
    required this.connected,
  });

  final String id;
  final String? name;
  final String? manufacturer;
  final bool connected;
}

enum WebMidiStateChangeType { connected, disconnected, changed }

class WebMidiStateChange {
  const WebMidiStateChange({required this.type, required this.portId});

  final WebMidiStateChangeType type;
  final String? portId;
}

typedef WebMidiMessageCallback = void Function(Uint8List data, int timestamp);

abstract class WebMidiBackend {
  Future<void> initialize();

  Stream<WebMidiStateChange> get onStateChanged;

  Future<List<WebMidiPortInfo>> listInputs();

  Future<List<WebMidiPortInfo>> listOutputs();

  Future<void> openInput(String portId, WebMidiMessageCallback onMessage);

  Future<void> closeInput(String portId);

  Future<void> openOutput(String portId);

  Future<void> closeOutput(String portId);

  void send(String outputPortId, Uint8List data, {int? timestamp});

  void dispose();
}
