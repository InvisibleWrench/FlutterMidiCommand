import 'web_midi_backend.dart';
import 'web_midi_backend_factory_stub.dart'
    if (dart.library.html) 'web_midi_backend_factory_web.dart'
    as impl;

WebMidiBackend createDefaultWebMidiBackend() =>
    impl.createDefaultWebMidiBackend();
