## 0.2.0
Migrated to federated plugin using platform interface

## 0.1.7
Bugfix - sending cabled MIDI on iOS 

## 0.1.6
Bugfix, android setup/plugin init

## 0.1.5

Updated Android plugin structure
Fixed iOS compilation error, with latest Dart
Fixed BLE Midi parsing on iOS


## 0.1.4

Updated Gradle version
Merge PR #8

## 0.1.3

Better handling of broadcast receiver on Android.

## 0.1.2

Fixed message splitting on iOS Bluetooth MIDI
Thanks to https://github.com/TheKashe for the contribution.

## 0.1.2

Better handling of disabled Bluetooth 

## 0.1.1

Added missing entitlement in iOS plist for bluetooth access

## 0.1.0

Moved Message Types into separate file: flutter_midi_command_messages.dart.
Fixed threading issue. https://github.com/InvisibleWrench/FlutterMidiCommand/issues/4
Added teardown function to disconnect and close all ports and devices.
Gradle dependency raised to 3.4.2
minSDKversion raised to 24
Version bumped to 0.1.0

## 0.0.8

Gradle and Kotlin update.
AndroidX

## 0.0.7

Updated readme

## 0.0.6

Added missing stopScanForDevices function on iOS

## 0.0.5

Updated kotlin version.
Specific MidiMessage type now exist as separate subtypes of MidiMessage.
Added StopScanning function.
Updated example.

## 0.0.4

Fixed stream broadcast bug

## 0.0.3

Added Support for BLE MIDI devices on iOS

## 0.0.2

Readme and formatting

## 0.0.1

Initial Release.
Functioning discovery and connection to MIDI devices on Android and iOS, as well as BLE MIDI devices on Android.
Functioning sending and receiving of MIDI data

