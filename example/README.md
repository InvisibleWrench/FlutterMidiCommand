# flutter_midi_command_example

Demonstrates how to use `flutter_midi_command` across native MIDI, BLE MIDI, virtual MIDI, and RTP/network session controls.

## What the example shows

- Independent transport toggles for `RTP`, `BLE`, and `Virtual`.
- A dedicated `Refresh Devices` action for reloading the current device snapshot.
- A separate `Scan BLE` action so Bluetooth discovery is decoupled from general device enumeration.
- Hot-plug updates through `onMidiSetupChanged`, including Windows USB MIDI attach/remove events.
- Device connection, controller-page interaction, and MIDI message sending/receiving.

## Notes

- BLE controls are only shown when the example is started with BLE enabled.
- `RTP` support depends on the host platform implementation.
- On Windows, multi-port USB MIDI devices are shown as full-duplex device pairs when matching input/output ports are detected.
