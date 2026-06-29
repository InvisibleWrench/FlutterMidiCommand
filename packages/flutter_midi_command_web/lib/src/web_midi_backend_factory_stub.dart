import 'dart:typed_data';

import 'web_midi_backend.dart';

WebMidiBackend createDefaultWebMidiBackend() => UnsupportedWebMidiBackend();

class UnsupportedWebMidiBackend implements WebMidiBackend {
  UnsupportedError _unsupported() {
    return UnsupportedError(
      'Web MIDI API is unavailable on this platform. '
      'Use Flutter web in a browser with Web MIDI support.',
    );
  }

  @override
  Future<void> initialize() async {
    throw _unsupported();
  }

  @override
  Stream<WebMidiStateChange> get onStateChanged =>
      const Stream<WebMidiStateChange>.empty();

  @override
  Future<List<WebMidiPortInfo>> listInputs() async {
    throw _unsupported();
  }

  @override
  Future<List<WebMidiPortInfo>> listOutputs() async {
    throw _unsupported();
  }

  @override
  Future<void> openInput(
    String portId,
    WebMidiMessageCallback onMessage,
  ) async {
    throw _unsupported();
  }

  @override
  Future<void> closeInput(String portId) async {
    throw _unsupported();
  }

  @override
  Future<void> openOutput(String portId) async {
    throw _unsupported();
  }

  @override
  Future<void> closeOutput(String portId) async {
    throw _unsupported();
  }

  @override
  void send(String outputPortId, Uint8List data, {int? timestamp}) {
    throw _unsupported();
  }

  @override
  void dispose() {}
}
