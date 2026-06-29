# flutter_midi_command_ble

[![pub package](https://img.shields.io/pub/v/flutter_midi_command_ble.svg)](https://pub.dev/packages/flutter_midi_command_ble)

Shared BLE MIDI transport for `flutter_midi_command`, implemented in Dart using `universal_ble`.

Use this package when you want BLE MIDI discovery/connection in addition to host/native MIDI transports.

## Usage

```dart
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

final midi = MidiCommand();
midi.configureBleTransport(UniversalBleMidiTransport());
```
