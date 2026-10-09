## 1.4.0

 - **FIX**: return futures from virtual device and network session APIs. ([e6bfa198](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e6bfa19827135e80d3ecea800a529a3b2b077144))
 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts. ([e86ad3e4](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e86ad3e42620a68f43a0e609ed767ddd8ac21264))
 - **FEAT**: BLE MIDI throughput, write integrity and diagnostics for 1.1.0. ([86fc04d0](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/86fc04d07e007263dc0d4592d55a82408c3e685f))

## 1.3.0

 - Bump "flutter_midi_command_web" to `1.3.0` and update the platform interface dependency constraint to `^1.3.0`. The Web MIDI API already delivers one complete message per event, so no parsing change was needed.

## 1.2.0

 - FIX: widen `addVirtualDevice`, `removeVirtualDevice` and `setNetworkSessionEnabled` to `Future<void>`, matching the platform interface. The unsupported-operation errors for virtual devices now arrive through the returned future.
 - Bump "flutter_midi_command_web" to `1.2.0` and update the platform interface dependency constraint to `^1.2.0`.

## 1.1.2

 - Bump "flutter_midi_command_web" to `1.1.2` and update the platform interface dependency constraint to `^1.1.2`.

## 1.1.1

 - Bump "flutter_midi_command_web" to `1.1.1` and update the platform interface dependency constraint to `^1.1.1`.

## 1.1.0

 - Bump "flutter_midi_command_web" to `1.1.0` and update the platform interface dependency constraint to `^1.1.0`.

## 1.0.9

 - Bump "flutter_midi_command_web" to `1.0.9` and update the platform interface dependency constraint.

## 1.0.8

 - Bump "flutter_midi_command_web" to `1.0.8` and update the platform interface dependency constraint.

## 1.0.7

 - Bump "flutter_midi_command_web" to `1.0.7` and update the platform interface dependency constraint.

## 1.0.6

 - Bump "flutter_midi_command_web" to `1.0.6`.

## 1.0.5

 - Bump "flutter_midi_command_web" to `1.0.5`.

## 1.0.4

 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts.

## 1.0.3

 - Update a dependency to the latest release.

## 1.0.2

## 1.0.1

 - Update a dependency to the latest release.

## 1.0.0

- Initial web implementation release for `flutter_midi_command`.
- Web MIDI backend for device enumeration, connect/disconnect, send, and receive.
