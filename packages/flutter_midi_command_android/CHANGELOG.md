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
