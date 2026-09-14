## 1.3.0

 - FIX: resolve running status correctly. `MidiPacketParser` latched a byte into `statusByte` before checking its length, so a clock (`0xF8`) clobbered the running status and every subsequent running-status note was **silently dropped** — the same user-visible symptom as [#179](https://github.com/InvisibleWrench/FlutterMidiCommand/issues/179) on a different transport.
 - FIX: a System Real-Time byte between two data bytes is emitted on its own instead of being appended as data, where a clock became the velocity.
 - FIX: System Common and SysEx clear the running status, and undefined status bytes no longer poison it.
 - FIX: a SysEx is bounded at 64 KiB and aborted by any non-real-time status byte, which is then re-dispatched — generalising the back-to-back-`F0` repair so a device that never sends `F7` cannot wedge the stream.
 - Update the platform interface dependency constraint to `^1.3.0`.

## 1.2.0

 - FIX(ios): do not create `MIDINetworkSession.default()` at plugin init. Touching it made iOS 14+ show the system "Allow [app] to find devices on local networks" permission prompt at app startup, even though network MIDI is disabled by default. The session is now created lazily in `setNetworkSessionEnabled(true)`, the existing explicit opt-in for network (RTP) MIDI. Thanks to @aleksei-svezhevskii.
 - Bump "flutter_midi_command_darwin" to `1.2.0` and update the platform interface dependency constraint to `^1.2.0`.

## 1.1.2

 - Bump "flutter_midi_command_darwin" to `1.1.2` and update the platform interface dependency constraint to `^1.1.2`.

## 1.1.1

 - Bump "flutter_midi_command_darwin" to `1.1.1` and update the platform interface dependency constraint to `^1.1.1`.

## 1.1.0

 - FIX: read every packet of a coalesced `MIDIPacketList` from the original list memory. The shared implementation copied only the first `MIDIPacket` — a fixed 256-byte struct — then walked `MIDIPacketNext` over that copy, so any packet after the first came from unrelated memory and anything longer than 256 bytes was truncated. Small coalesced packets appeared to work because the struct copy happened to carry them along, so this surfaced only with large SysEx or more than 256 bytes of coalesced data. Virtual devices used the broken path; native devices already had a correct override, which is now shared rather than duplicated.
 - BREAKING (virtual devices only): timestamps from virtual devices are now converted to nanoseconds via `mach_timebase_info`, matching what native devices already reported, instead of being passed through as raw mach ticks.
 - Bump "flutter_midi_command_darwin" to `1.1.0` and update the platform interface dependency constraint to `^1.1.0`.

## 1.0.9

 - Bump "flutter_midi_command_darwin" to `1.0.9` and update the platform interface dependency constraint.

## 1.0.8

 - FIX: report CoreMIDI destinations as `inputPorts` and sources as `outputPorts` so port direction matches the public device-owned API contract (#164).
 - Update the platform interface dependency constraint to `^1.0.8`.

## 1.0.7

 - Bump "flutter_midi_command_darwin" to `1.0.7` and update the platform interface dependency constraint.

## 1.0.6

 - Bump "flutter_midi_command_darwin" to `1.0.6`.

## 1.0.5

 - Bump "flutter_midi_command_darwin" to `1.0.5`.

## 1.0.4

 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts.

## 1.0.3

 - Update a dependency to the latest release.

## 1.0.2

 - N

## 1.0.1

 - Update a dependency to the latest release.

## 1.0.0

- Initial federated Darwin (iOS/macOS) implementation release in monorepo layout.
- Host MIDI API contracts migrated to generated Pigeon interfaces.
