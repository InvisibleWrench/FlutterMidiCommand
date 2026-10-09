## 1.4.0

 - **FIX**(android,darwin): resolve running status correctly in the native parsers. ([2a972fa4](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/2a972fa4a00efaca7f7bfd5b6c50743118695b00))
 - **FIX**(darwin): create MIDINetworkSession lazily, not at plugin init. ([a28af471](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/a28af47169db4bbaaa1b5d9bb66824a0d14a9966))
 - **FIX**(darwin): iterate original MIDIPacketList memory when receiving. ([0f2a4709](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/0f2a47098d8d9179b504d55db81dfb737f738a13))
 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts. ([e86ad3e4](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e86ad3e42620a68f43a0e609ed767ddd8ac21264))
 - **FEAT**: BLE MIDI throughput, write integrity and diagnostics for 1.1.0. ([86fc04d0](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/86fc04d07e007263dc0d4592d55a82408c3e685f))
 - **DOCS**(darwin): explain lazy network session creation. ([e9f0e249](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e9f0e249238087064665c88622d82eb30536d78a))
 - **DOCS**: record the darwin packet-list fix in the 1.1.0 changelogs. ([fb44893d](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/fb44893dc8f17cd3a2b7b3e54d8f3f0570b0084a))

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
