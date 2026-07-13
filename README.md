# Flutter MIDI Command

[![CI](https://github.com/InvisibleWrench/FlutterMidiCommand/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/InvisibleWrench/FlutterMidiCommand/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_midi_command.svg)](https://pub.dev/packages/flutter_midi_command)
[![pub points](https://img.shields.io/pub/points/flutter_midi_command)](https://pub.dev/packages/flutter_midi_command/score)
[![pub likes](https://img.shields.io/pub/likes/flutter_midi_command)](https://pub.dev/packages/flutter_midi_command/score)
[![License](https://img.shields.io/github/license/InvisibleWrench/FlutterMidiCommand)](https://github.com/InvisibleWrench/FlutterMidiCommand/blob/main/LICENSE)

A Flutter plugin for sending and receiving MIDI messages between Flutter and physical and virtual MIDI devices.

Wraps CoreMIDI/android.media.midi/ALSA/win32 in a thin Dart/Flutter layer.
Includes a built-in typed MIDI parser/generator (`MidiMessageParser` and `MidiMessage.parse`); see [Message parser](#message-parser).
Supports

| Transports | iOS | macOS | Android | Linux | Windows | Web |
|---|---|---|---|---|---|---|
| USB | &check; | &check; | &check; | &check; | &check; | &check;* |
| BLE | &check; | &check; | &check; | &cross; | &check; | &cross;** |
| Virtual | &check; | &check; | &check; | &cross; | &cross; | &cross; |
| Network Session | &check; | &check; | &cross; | &cross; | &cross; | &cross; |

\* via browser Web MIDI API support.
\** BLE MIDI on Web is not handled by `flutter_midi_command_ble`; Web MIDI exposure depends on browser/OS.


## To install

- Make sure your project is created with Kotlin and Swift support.
- Add `flutter_midi_command` to your `pubspec.yaml`.
- Add `flutter_midi_command_ble` only if you want BLE MIDI support.
- Minimum platform versions in this repo:
  - iOS: plugin package minimum is `11.0` (`packages/flutter_midi_command_darwin/ios/flutter_midi_command_darwin.podspec`), while the example app currently targets `13.0` (`example/ios/Podfile`).
  - macOS: plugin package minimum is `10.13` (`packages/flutter_midi_command_darwin/macos/flutter_midi_command_darwin.podspec`), while the example app currently targets `10.15` (`example/macos/Podfile`).
  - Android: plugin package minimum is `minSdkVersion(21)` (`packages/flutter_midi_command_android/android/build.gradle.kts`), while the example app currently uses `minSdkVersion(24)` (`example/android/app/build.gradle.kts`).
- Android BLE permissions are merged automatically when `flutter_midi_command_ble` is installed.
- Apple usage descriptions/capabilities and packaged Windows/Linux permissions remain application-owned. See the [BLE platform setup guide](https://pub.dev/packages/flutter_midi_command_ble#platform-setup).
- If using network MIDI on iOS, add `NSLocalNetworkUsageDescription`.
- On Linux, make sure ALSA is installed.
- On Web, use HTTPS and a browser with Web MIDI enabled (for example Chrome/Edge).

## Getting Started

The snippet below shows a practical integration pattern with optional BLE, device discovery, connection, and send/receive flow.

```dart
import 'dart:async';

import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
// Optional: remove this import and BLE setup if your app is native-only.
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

class MidiSessionController {
  MidiSessionController({required this.enableBle});

  final bool enableBle;
  final MidiCommand midi = MidiCommand();
  StreamSubscription<MidiDataReceivedEvent>? _rxSub;
  StreamSubscription<MidiSetupChange>? _setupSub;
  MidiDevice? selectedDevice;

  Future<void> initialize() async {
    if (enableBle) {
      midi.configureBleTransport(UniversalBleMidiTransport());
      await midi.startBluetooth();
      await midi.waitUntilBluetoothIsInitialized();
      await midi.startScanningForBluetoothDevices();
    } else {
      midi.configureBleTransport(null);
      midi.configureTransportPolicy(
        const MidiTransportPolicy(
          excludedTransports: {MidiTransport.ble},
        ),
      );
    }

    _setupSub = midi.onMidiSetupChanged?.listen((_) async {
      final devices = await midi.devices ?? const <MidiDevice>[];
      if (devices.isNotEmpty && selectedDevice == null) {
        selectedDevice = devices.first;
      }
    });

    _rxSub = midi.onMidiDataReceived?.listen((event) {
      _handleIncomingMessage(
        event.device,
        event.transport,
        event.timestamp,
        event.message,
      );
    });
  }

  Future<void> connectFirstMatching(String query) async {
    final devices = await midi.devices ?? const <MidiDevice>[];
    final q = query.toLowerCase();
    final device = devices.firstWhere(
      (d) => d.name.toLowerCase().contains(q),
      orElse: () => throw StateError('No MIDI device found for "$query".'),
    );
    try {
      await midi.connectToDevice(device);
    } on MidiConnectionTimeoutException catch (e) {
      // Timed out while waiting for a usable MIDI connection.
      print('Connection timed out at ${e.stage}: ${e.message}');
      rethrow;
    } on MidiPairingRejectedException catch (e) {
      // The user rejected the OS pairing/bonding prompt, or pairing did not complete.
      print('Pairing rejected: ${e.message}');
      rethrow;
    } on MidiConnectionException catch (e) {
      // Other connection-readiness failures such as service discovery,
      // notification subscription, or CoreMIDI handoff.
      print('Connection failed at ${e.stage}: ${e.message}');
      rethrow;
    }
    selectedDevice = device;
  }

  void sendMiddleC() {
    final targetId = selectedDevice?.id;
    midi.sendData(
      NoteOnMessage(channel: 0, note: 60, velocity: 100).generateData(),
      deviceId: targetId,
    );
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      midi.sendData(
        NoteOffMessage(channel: 0, note: 60, velocity: 0).generateData(),
        deviceId: targetId,
      );
    });
  }

  void _handleIncomingMessage(
    MidiDevice source,
    MidiTransport transport,
    int timestamp,
    MidiMessage message,
  ) {
    if (message is NoteOnMessage) {
      // Example: route to synth engine / UI.
      return;
    }
    if (message is CCMessage) {
      // Example: map controllers to parameters.
      return;
    }
    if (message is SysExMessage) {
      // Example: parse manufacturer-specific payload.
      return;
    }
    // Handle other typed messages as needed (PitchBendMessage, NRPN4Message, etc).
  }

  Future<void> dispose() async {
    await _rxSub?.cancel();
    await _setupSub?.cancel();
    if (enableBle) {
      midi.stopScanningForBluetoothDevices();
    }
    midi.dispose();
  }
}
```

`connectToDevice` completes when the MIDI path is ready for use, or throws. The default `awaitConnectionTimeout` is 30 seconds and covers the full connection-readiness flow, not just the initial radio/socket connection. For BLE MIDI this includes BLE connection, service discovery, pairing/bonding through native UI when required, notification subscription, and on Apple platforms the CoreMIDI handoff for bonded BLE MIDI devices.

Connection failures are surfaced as typed `MidiConnectionException` subclasses where possible:

- `MidiConnectionTimeoutException`: the readiness flow exceeded `awaitConnectionTimeout`.
- `MidiPairingRejectedException`: pairing/bonding was rejected or did not complete.
- `MidiPairingFailedException`: pairing failed before a clear rejection was reported.
- `MidiServiceDiscoveryException`: the BLE MIDI service/characteristic was not found.
- `MidiNotificationSubscriptionException`: BLE MIDI notifications could not be enabled.
- `MidiCoreMidiHandoffException`: a paired Apple BLE MIDI device was not exposed through CoreMIDI.

Pass `awaitConnectionTimeout: null` only if you explicitly want to let the readiness flow wait indefinitely.

### Setup change events

Listen to `onMidiSetupChanged` to refresh your device list when the host MIDI topology changes. Native desktop/mobile transports monitor platform setup notifications and emit `MidiSetupChange` values:

- `MidiSetupChange.deviceAppeared`: a MIDI device or logical port became available.
- `MidiSetupChange.deviceDisappeared`: a MIDI device or logical port was removed.
- `MidiSetupChange.deviceStateChanged`: an existing device changed name, port shape, or availability state.
- `MidiSetupChange.deviceConnected`: this app connected to a device.
- `MidiSetupChange.deviceDisconnected`: this app disconnected from a device, or a connected device was removed.

Android, iOS/macOS, Linux, Windows, and Web use platform notifications to wake a fresh device snapshot and emit setup events only after a real MIDI-device change is observed. BLE MIDI is scan-driven: `MidiSetupChange.deviceAppeared` is emitted for scan results, and connection loss is emitted as `MidiSetupChange.deviceDisconnected`.

On Windows, native device monitoring now keeps USB MIDI hot-plug changes in sync with `devices`, and multi-port WinMM endpoints are paired into full-duplex devices when matching input/output port sets can be inferred consistently.

See `example/` for a complete app with:

- independent transport toggles for RTP, BLE, and Virtual MIDI
- a manual `Refresh Devices` action for the current device snapshot
- a separate `Scan BLE` action so Bluetooth discovery does not double as general device refresh

## Message parser

`onMidiDataReceived` already emits typed MIDI messages.
Use `MidiMessageParser` (or `MidiMessage.parse`) when you need to parse raw bytes from `onMidiPacketReceived` or from custom byte streams.
Keep one parser instance per input stream/device to preserve running-status and partial-message state correctly.

- Supports running status.
- Handles realtime bytes interleaved with channel and SysEx data.
- Reassembles split packets across callback boundaries.
- Recovers from malformed/incomplete byte sequences and resumes on the next valid status byte.

```dart
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';

final MidiMessageParser parser = MidiMessageParser();

void onPacket(MidiPacket packet) {
  final messages = parser.parse(packet.data, flushPendingNrpn: false);
  for (final message in messages) {
    if (message is NoteOnMessage) {
      print('NoteOn ch=${message.channel} note=${message.note} vel=${message.velocity}');
    } else if (message is PitchBendMessage) {
      print('Pitch bend ch=${message.channel} value=${message.bend}');
    } else if (message is NRPN4Message) {
      print('NRPN param=${message.parameter} value=${message.value}');
    } else if (message is SysExMessage) {
      print('SysEx bytes=${message.data.length}');
    }
  }
}

void onStreamClosed() {
  // Flush pending partial NRPN/RPN state, if any.
  final flushed = parser.parse(Uint8List(0), flushPendingNrpn: true);
  for (final message in flushed) {
    // Handle final pending message.
  }
  parser.reset();
}
```

For simple one-shot payloads you can also call:

```dart
final messages = MidiMessage.parse(packet.data);
```

### Dependency examples

With native transports only:

```yaml
dependencies:
  flutter_midi_command: ^1.0.0
```

With BLE support enabled:

```yaml
dependencies:
  flutter_midi_command: ^1.0.0
  flutter_midi_command_ble: ^1.0.0
```

## Migration Guide (from older plugin versions)

### 1) BLE moved to an optional package

If you previously relied on built-in BLE behavior, add and attach the BLE transport explicitly:

```yaml
dependencies:
  flutter_midi_command: ^1.0.0
  flutter_midi_command_ble: ^1.0.0
```

```dart
final midi = MidiCommand();
midi.configureBleTransport(UniversalBleMidiTransport());
```

If you want to remove BLE entirely, omit `flutter_midi_command_ble` and/or call:

```dart
midi.configureBleTransport(null);
```

For local workspace development (like this monorepo), `path:` dependencies are still valid and used by the example app.

### 2) Bluetooth API rename

- Old: `startBluetoothCentral()`
- New: `startBluetooth()`

`onBluetoothStateChanged` and `bluetoothState` are still available.

### 3) `MidiDevice.type` changed from `String` to enum

Use `MidiDeviceType` instead of string comparisons:

```dart
if (device.type == MidiDeviceType.ble) {
  // ...
}
```

If you still need old wire values for logging or compatibility, use `device.type.wireValue`.

### 4) Connection semantics are stricter

`await midi.connectToDevice(device)` now resolves only when the MIDI path is ready for use (or throws on failure/timeout), so completion means a real connected state. The default timeout is 30 seconds and is a full connection-readiness budget. For BLE MIDI it covers BLE connection, service discovery, native pairing/bonding UI if required, notification subscription, and Apple CoreMIDI handoff when that is the data path.

Connection failures use typed exceptions such as `MidiConnectionTimeoutException`, `MidiPairingRejectedException`, and `MidiCoreMidiHandoffException`, all deriving from `MidiConnectionException`.

`MidiDevice` also exposes `onConnectionStateChanged` for reactive flows.

### 5) Transport policies are first-class

Use `MidiTransportPolicy` to enable/disable transports at runtime. Transport-specific calls throw `StateError` when that transport is disabled.

### 6) Host-paired Bluetooth MIDI devices may be native-routed

A host-native device can report `MidiDeviceType.ble` while still communicating through host MIDI APIs (for example paired CoreMIDI/Android host devices). Do not assume `type == ble` always means Dart BLE transport is used internally.

For help getting started with Flutter, view our online
[documentation](https://flutter.dev/).

For help on editing plugin code, view the [documentation](https://docs.flutter.dev/development/packages-and-plugins/developing-packages#edit-plugin-package).

## Workspace and architecture

This repository is now managed as a melos monorepo.

### Packages

- `flutter_midi_command` (this package): public API and transport policies
- `packages/flutter_midi_command_platform_interface`: shared platform contracts
- `packages/flutter_midi_command_linux`: Linux host MIDI wrapper
- `packages/flutter_midi_command_windows`: Windows host MIDI wrapper
- `packages/flutter_midi_command_ble`: shared BLE MIDI transport using `universal_ble`
- `packages/flutter_midi_command_web`: browser Web MIDI transport
  See `packages/flutter_midi_command_web/README.md` for web-specific runtime/permission details.

### Transport policies

You can include/exclude transports at runtime:

```dart
final midi = MidiCommand();
midi.configureTransportPolicy(
  const MidiTransportPolicy(
    excludedTransports: {MidiTransport.ble},
  ),
);
```

When a transport is disabled, transport-specific calls throw a `StateError`.

### Device types

`MidiDevice.type` is now strongly typed as `MidiDeviceType` (for example `MidiDeviceType.serial`, `MidiDeviceType.ble`, `MidiDeviceType.virtual`).

### Device connection state

Each `MidiDevice` now exposes connection state updates:

```dart
final sub = selectedDevice.onConnectionStateChanged.listen((state) {
  // state is MidiConnectionState.disconnected/connecting/connected/disconnecting
});
```

### Compile-time BLE include/exclude

Direct BLE scan/connect is optional at dependency level:

- If you only depend on `flutter_midi_command`, no shared Dart BLE scanner/transport is attached.
- To include shared Dart BLE discovery/connection, add `flutter_midi_command_ble` and attach it to `MidiCommand`:

```dart
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

final midi = MidiCommand();
midi.configureBleTransport(UniversalBleMidiTransport());
```

To disable BLE completely:

```dart
midi.configureBleTransport(null);
```

Note: paired Bluetooth MIDI devices exposed by host native MIDI APIs can still appear in `MidiCommand().devices` with `MidiDeviceType.ble` and connect through the native backend.

The normal BLE API remains unchanged:

```dart
await midi.startBluetooth();
await midi.startScanningForBluetoothDevices();
final state = midi.bluetoothState;
final stateStream = midi.onBluetoothStateChanged;
```

BLE `connectToDevice` completion means the BLE MIDI path is ready. On platforms without an explicit pairing API, such as Apple platforms, the transport triggers native pairing/bonding by accessing the encrypted MIDI characteristic and waits for that readiness step to finish or fail.

### Architecture note

`MidiCommandPlatform` now only describes native host MIDI operations.
Shared BLE discovery/connection lives in `MidiBleTransport`, implemented in Dart (`flutter_midi_command_ble`).
Host-native backends may also report paired Bluetooth devices as `MidiDeviceType.ble`.
Web MIDI is implemented by `flutter_midi_command_web` using browser Web MIDI APIs.

### Native API contracts with Pigeon

Pigeon definitions are tracked in `pigeons/midi_api.dart` and should be used as the source-of-truth for generated host/flutter messaging code.
