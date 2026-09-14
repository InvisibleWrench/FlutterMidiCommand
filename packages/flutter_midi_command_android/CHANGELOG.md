## 1.3.0

 - FIX: resolve running status correctly. `MidiPacketParser` latched a byte into `statusByte` before checking its length, so a clock (`0xF8`) clobbered the running status and every subsequent running-status note was **silently dropped** — the same user-visible symptom as [#179](https://github.com/InvisibleWrench/FlutterMidiCommand/issues/179) on a different transport.
 - FIX: a System Real-Time byte between two data bytes is emitted on its own instead of being appended as data, where a clock became the velocity.
 - FIX: System Common and SysEx clear the running status, and undefined status bytes no longer poison it.
 - FIX: a SysEx is bounded at 64 KiB and aborted by any non-real-time status byte, which is then re-dispatched — generalising the back-to-back-`F0` repair so a device that never sends `F7` cannot wedge the stream.
 - FIX: virtual devices parse incoming MIDI like hardware devices do. `VirtualRXReceiver` forwarded raw byte slices, so running status reached apps unresolved on the virtual path. Both receivers now share one parser, and the receiver reads its callback at send time rather than at construction.
 - Update the platform interface dependency constraint to `^1.3.0`.

## 1.2.0

 - Bump "flutter_midi_command_android" to `1.2.0` and update the platform interface dependency constraint to `^1.2.0`.

## 1.1.2

 - Bump "flutter_midi_command_android" to `1.1.2` and update the platform interface dependency constraint to `^1.1.2`.

## 1.1.1

 - Bump "flutter_midi_command_android" to `1.1.1` and update the platform interface dependency constraint to `^1.1.1`.

## 1.1.0

 - Bump "flutter_midi_command_android" to `1.1.0` and update the platform interface dependency constraint to `^1.1.0`.

## 1.0.9

 - Bump "flutter_midi_command_android" to `1.0.9` and update the platform interface dependency constraint.

## 1.0.8

 - FIX(android): disable Kotlin incremental compilation for the Android plugin on Windows hosts to avoid Kotlin cache failures when the app project and Pub cache are on different drives (#163).
 - Update the platform interface dependency constraint to `^1.0.8`.

## 1.0.7

 - Bump "flutter_midi_command_android" to `1.0.7` and update the platform interface dependency constraint.

## 1.0.6

 - FIX(android): survive an `IOException: EPIPE` from a removed device during `ConnectedDevice` teardown, so unplugging a connected USB MIDI device no longer crashes the app; disconnection notifications still fire (#158).

## 1.0.5

 - Bump "flutter_midi_command_android" to `1.0.5`.

## 1.0.4

 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts.
 - **FEAT**(ble): bundle Android permissions and document platform setup.

## 1.0.3

 - Update a dependency to the latest release.

## 1.0.2

## 1.0.1

 - Update a dependency to the latest release.

## 1.0.0

- Initial federated Android implementation release in monorepo layout.
- Host MIDI API contracts migrated to generated Pigeon interfaces.
