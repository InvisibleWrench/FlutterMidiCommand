# flutter_midi_command

A Flutter plugin for sending and receiving MIDI messages between Flutter and physical and virtual MIDI devices.

Wraps CoreMIDI/android.media.midi/ALSA in a thin dart/flutter layer.
Supports

- USB and BLE MIDI connections on Android
- USB, network(session), virtual MIDI devices and BLE MIDI connections on iOS and macOS.
- ALSA Midi on Linux
- Create own virtual MIDI devices on iOS

## To install

- Make sure your project is created with Kotlin and Swift support.
- Add flutter_midi_command: ^0.4.0-dev.1 to your pubspec.yaml file.
- In ios/Podfile uncomment and change the platform to 10.0 `platform :ios, '10.0'`
- On iOS, After building, Add a NSBluetoothAlwaysUsageDescription and NSLocalNetworkUsageDescription to info.plist in the generated Xcode project.
- On Linux, make sure ALSA is installed.

## Getting Started

This plugin is build using Swift and Kotlin on the native side, so make sure your project supports this.

Import flutter_midi_command

`import 'package:flutter_midi_command/flutter_midi_command.dart';`

- Get a list of available MIDI devices by calling `MidiCommand().devices` which returns a list of `MidiDevice`
- Start bluetooth subsystem by calling `MidiCommand().startBluetoothCentral()`
- Observe the bluetooth system state by calling `MidiCommand().onBluetoothStateChanged()`
- Get the current bluetooth system state by calling `MidiCommand().bluetoothState()`
- Start scanning for BLE MIDI devices by calling `MidiCommand().startScanningForBluetoothDevices()`
- Connect to a specific `MidiDevice` by calling `MidiCommand.connectToDevice(selectedDevice)`
- Stop scanning for BLE MIDI devices by calling `MidiCommand().stopScanningForBluetoothDevices()`
- Disconnect from the current device by calling `MidiCommand.disconnectDevice()`
- Listen for updates in the MIDI setup by subscribing to `MidiCommand().onMidiSetupChanged`
- Listen for incoming MIDI messages on from the current device by subscribing to `MidiCommand().onMidiDataReceived`, after which the listener will recieve inbound MIDI messages as an UInt8List of variable length.
- Send a MIDI message by calling `MidiCommand.sendData(data)`, where data is an UInt8List of bytes following the MIDI spec.
- Or use the various `MidiCommand` subtypes to send PC, CC, NoteOn and NoteOff messages.
- Use `MidiCommand().addVirtualDevice(name: "Your Device Name")` to create a virtual MIDI destination and a virtual MIDI source. These virtual MIDI devices show up in other apps and can be used by other apps to send and receive MIDI to or from your app. The name parameter is ignored on Android and the Virtual Device is always called FlutterMIDICommand. To make this feature work on iOS, enable background audio for your app, i.e., add key `UIBackgroundModes` with value `audio` to your app's `info.plist` file.

See example folder for how to use.

For help getting started with Flutter, view our online
[documentation](https://flutter.io/).

For help on editing plugin code, view the [documentation](https://flutter.io/pwd
developing-packages/#edit-plugin-package).
