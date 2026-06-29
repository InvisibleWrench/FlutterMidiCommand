# Flutter MIDI Command architecture (monorepo migration)

## Goals

- Use a melos workspace for coordinated package versioning and CI.
- Keep platform code focused on serial/virtual host MIDI APIs.
- Keep BLE behavior in shared Dart logic (using `universal_ble` in follow-up packages).
- Define host <-> Flutter contracts through Pigeon.
- Expose transport capabilities and policy controls to apps.

## Current baseline in this branch

- `melos.yaml` introduces workspace scripts for analyze/test/format.
- `pigeons/midi_api.dart` defines source-of-truth host and flutter APIs.
- `MidiTransportPolicy` and `MidiCapabilities` are exposed in Dart.
- `MidiCommand.configureTransportPolicy(...)` allows include/exclude control per transport.

## Implemented structure

- Packages are split under `packages/` for platform wrappers plus shared BLE transport.
- Android and Linux wrappers focus on host/native serial MIDI behavior.
- Host/Flutter messaging contracts are generated from `pigeons/midi_api.dart` through Pigeon.
- The web package (`flutter_midi_command_web`) now wraps the browser Web MIDI API for serial/native MIDI access.

## Ongoing work

- Expand native-only test automation (Android/iOS/macOS) in CI.
- Expand browser-level automated tests for Web MIDI behavior and edge cases.
