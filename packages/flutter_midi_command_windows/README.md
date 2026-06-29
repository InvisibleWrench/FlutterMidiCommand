# flutter_midi_command_windows

[![pub package](https://img.shields.io/pub/v/flutter_midi_command_windows.svg)](https://pub.dev/packages/flutter_midi_command_windows)

Windows implementation of [FlutterMidiCommand](https://pub.dev/packages/flutter_midi_command).

## Current behavior

- Enumerates WinMM MIDI input/output endpoints and exposes them as `MidiDevice`s.
- Emits `onMidiSetupChanged` events when Windows MIDI topology changes, including USB hot-plug attach/remove updates.
- Pairs balanced multi-port WinMM endpoints into full-duplex devices when matching input/output groups can be inferred from endpoint names.

## Limitations

- Uses the WinMM MIDI API rather than the newer Windows MIDI Services stack.
- Virtual device creation and RTP/network session APIs are not implemented on Windows.
