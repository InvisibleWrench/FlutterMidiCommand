## 1.4.0

 - **FIX**(windows,linux): deliver complete, private MIDI messages. ([4f123831](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/4f123831a322e6c9c25c4e046bfb079f9f52df0e))
 - **FIX**: return futures from virtual device and network session APIs. ([e6bfa198](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e6bfa19827135e80d3ecea800a529a3b2b077144))
 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts. ([e86ad3e4](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/e86ad3e42620a68f43a0e609ed767ddd8ac21264))
 - **FEAT**: BLE MIDI throughput, write integrity and diagnostics for 1.1.0. ([86fc04d0](https://github.com/InvisibleWrench/FlutterMidiCommand/commit/86fc04d07e007263dc0d4592d55a82408c3e685f))

## 1.3.0

 - FIX: a SysEx spanning more than one input buffer arrives whole. The parser accumulated the chunks but then delivered only the last one, so a long SysEx was truncated to its tail.
 - FIX: two devices receiving SysEx at the same time no longer interleave into each other's message. The assembly buffer was a file-global shared by every open device; each device now has its own.
 - FIX: delivered bytes are a copy. They used to be a live view of the `MIDIHDR` buffer that was immediately re-queued with the driver, so they could be overwritten under the listener.
 - FIX: a SysEx the device never terminates no longer permanently consumes one of the four input buffers. The header is re-queued whatever the chunk contained, and an unterminated message is force-terminated at 64 KiB.
 - Update the platform interface dependency constraint to `^1.3.0`.

## 1.2.0

 - FIX: widen `addVirtualDevice`, `removeVirtualDevice` and `setNetworkSessionEnabled` to `Future<void>`, matching the platform interface.
 - Bump "flutter_midi_command_windows" to `1.2.0` and update the platform interface dependency constraint to `^1.2.0`.

## 1.1.2

 - Bump "flutter_midi_command_windows" to `1.1.2` and update the platform interface dependency constraint to `^1.1.2`.

## 1.1.1

 - Bump "flutter_midi_command_windows" to `1.1.1` and update the platform interface dependency constraint to `^1.1.1`.

## 1.1.0

 - Bump "flutter_midi_command_windows" to `1.1.0` and update the platform interface dependency constraint to `^1.1.0`.

## 1.0.9

 - Bump "flutter_midi_command_windows" to `1.0.9` and update the platform interface dependency constraint.

## 1.0.8

 - Bump "flutter_midi_command_windows" to `1.0.8` and update the platform interface dependency constraint.

## 1.0.7

 - Bump "flutter_midi_command_windows" to `1.0.7` and update the platform interface dependency constraint.

## 1.0.6

 - Bump "flutter_midi_command_windows" to `1.0.6`.

## 1.0.5

 - Bump "flutter_midi_command_windows" to `1.0.5`.

## 1.0.4

 - Updated the platform interface dependency constraint to `^1.0.4`.

## 1.0.3

 - Updated the platform interface dependency constraint to `^1.0.3`.

## 1.0.2

 - **FIX**: port to win32 6, csv 8 and file_picker 12 APIs.

## 1.0.1

 - Update a dependency to the latest release.

## 1.0.0

* Major release aligned with the federated monorepo architecture.
* Updated to the 1.x platform interface and typed host models.
* Replaced third-party USB change monitoring with native Windows device notifications.
* Improved multi-port enumeration so balanced WinMM endpoint groups surface as full-duplex devices.
* Fixed short-message handling in the WinMM input callback path.

## 0.3.0

* Updated device_manager package to 0.0.7, which includes the fix for Windows
* Updated UniversalBle package to 0.21.0, with minor API changes

## 0.2.0

* Use device_manager package for USB device detection.

## 0.1.0

* Cleanup

## 0.0.1-dev.9

* Specify UniversalBle git dependecy


## 0.0.1-dev.8

* Added overrides for network session controls


## 0.0.1-dev.7

* Added BLE Support


## 0.0.1-dev.6

* Split into windows_midi_device.
* Better port enumeration
* Better device monitoring.


## 0.0.1-dev.5

* Added device monitoring, to notify when devices attach/detach


## 0.0.1-dev.4

* Fixed sending using midiOutLongMsg


## 0.0.1-dev.3

* Def update


## 0.0.1-dev.2

* License update


## 0.0.1-dev.1

* First release. No BLE Support, No Virtual Devices
