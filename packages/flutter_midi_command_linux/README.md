# flutter_midi_command_linux

[![pub package](https://img.shields.io/pub/v/flutter_midi_command_linux.svg)](https://pub.dev/packages/flutter_midi_command_linux)

This is the Linux specific implementation of [FlutterMidiCommand](https://pub.dev/packages/flutter_midi_command)

This package is implemented in Dart and registers through `dartPluginClass`.
It talks to ALSA MIDI devices through the `midi` package and does not ship a
native C++ Flutter Linux plugin.

## Limitations

Virtual MIDI source creation is currently not implemented on Linux.
