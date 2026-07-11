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

`await midi.connectToDevice(device)` completes only when the BLE MIDI path is ready for use. The public `awaitConnectionTimeout` from `MidiCommand.connectToDevice` is treated as a full readiness budget and is passed down to this transport.

The BLE readiness flow includes:

- BLE connection
- MIDI service and characteristic discovery
- pairing/bonding when required
- notification subscription

On platforms without an explicit pairing API, such as iOS and macOS, pairing is triggered by accessing the encrypted MIDI characteristic and failures are surfaced as typed `MidiConnectionException` subclasses from `flutter_midi_command_platform_interface`.
