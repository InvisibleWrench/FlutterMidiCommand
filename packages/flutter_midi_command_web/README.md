# flutter_midi_command_web

[![pub package](https://img.shields.io/pub/v/flutter_midi_command_web.svg)](https://pub.dev/packages/flutter_midi_command_web)

Web implementation of `flutter_midi_command` backed by the browser Web MIDI API.

## What it supports

- Enumerating MIDI input/output ports as `MidiDevice`
- Connecting/disconnecting to discovered devices
- Receiving MIDI packets from input ports
- Sending MIDI packets to output ports
- Emitting setup-change events when browser MIDI ports appear/disappear

## What it does not support

- Virtual MIDI devices (`addVirtualDevice` / `removeVirtualDevice`)
- iOS/macOS network session APIs (`isNetworkSessionEnabled` / `setNetworkSessionEnabled`)
- BLE via `flutter_midi_command_ble` on web

## Browser requirements

- HTTPS origin (or localhost during development)
- Browser with Web MIDI API support (typically Chrome/Edge)
- User permission granted for MIDI access

If the browser does not expose `navigator.requestMIDIAccess`, API calls will throw `UnsupportedError`.

## Notes on permissions and SysEx

The implementation requests MIDI access with SysEx enabled (`sysex: true`).
If SysEx permission is denied by the browser/user policy, initialization may fail and surface as an error from `devices`/`connectToDevice`.

## Testing

This package includes backend-injected unit tests in `test/flutter_midi_command_web_test.dart`.
Run in a browser with:

```sh
flutter test --platform chrome
```
