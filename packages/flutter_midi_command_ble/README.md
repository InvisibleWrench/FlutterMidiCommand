# flutter_midi_command_ble

[![pub package](https://img.shields.io/pub/v/flutter_midi_command_ble.svg)](https://pub.dev/packages/flutter_midi_command_ble)

Shared BLE MIDI transport for `flutter_midi_command`, implemented in Dart using `universal_ble`.

Use this package when you want BLE MIDI discovery/connection in addition to host/native MIDI transports.

## Platform setup

Platform security configuration belongs to the application, except on Android where this package can safely provide the standard BLE MIDI manifest declarations. Installing the package does not bypass runtime permission prompts; applications must still handle permission denial and explain why Bluetooth access is needed.

| Platform | Setup |
|---|---|
| Android | Manifest permissions are included automatically by this package. |
| iOS | Add a Bluetooth usage description; opt into background operation only if the app needs it. |
| macOS | Add a Bluetooth usage description and Bluetooth app-sandbox entitlement. |
| Windows | Add Bluetooth/radio capabilities when publishing a packaged application. |
| Linux | Ensure BlueZ is available and grant access through the chosen packaging format. |
| Web | BLE MIDI is not provided by this package; browser/OS Web MIDI support applies. |

### Android

The package's Android library manifest automatically contributes the permissions needed for BLE MIDI on both legacy Android versions and Android 12+. No permission declarations are normally needed in the application's `AndroidManifest.xml`.

The included `BLUETOOTH_SCAN` declaration uses `neverForLocation`, because BLE MIDI discovery does not derive physical location. Android may filter some beacon-style advertisements under this mode. An application that also uses BLE scanning for location or beacon detection must override that declaration and request the corresponding location permission itself.

Runtime permission is requested by the BLE transport when Bluetooth starts. The application remains responsible for handling denial and directing the user to settings when appropriate.

### iOS

Add an application-specific explanation to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connect to Bluetooth MIDI devices.</string>
```

Only applications that need BLE connections to be restored or maintained in the background should also enable the **Uses Bluetooth LE accessories** background capability. That produces:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

These values cannot be supplied reliably by a dependency because the permission explanation and background policy belong to the host application.

### macOS

Add `NSBluetoothAlwaysUsageDescription` to `macos/Runner/Info.plist` using an application-specific explanation. For a sandboxed app, add the following to both `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

This is the Xcode **Bluetooth** app-sandbox capability.

### Windows

No capability declaration is needed for an ordinary unpackaged Flutter desktop build. When publishing as MSIX or another packaged Windows application, declare the `bluetooth` device capability and the restricted `radios` capability in the application package manifest. These are packaging-level declarations and cannot be injected by this Dart package.

### Linux

The application needs access to the system BlueZ service. Native/unpackaged applications normally use the host's D-Bus and user permissions. Sandboxed packaging must expose BlueZ explicitly; for example, a Snap package should declare the `bluez` plug. The exact configuration belongs to the application's distribution format.

### Web

`flutter_midi_command_ble` does not currently expose BLE MIDI through Web Bluetooth. On the web, MIDI device exposure is controlled by browser and operating-system Web MIDI support, including the browser's runtime permission prompt.

## Usage

```dart
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

final midi = MidiCommand();
midi.configureBleTransport(UniversalBleMidiTransport());
```

`await midi.connectToDevice(device)` completes only when the BLE MIDI path is ready for use. The public `awaitConnectionTimeout` from `MidiCommand.connectToDevice` is treated as a full readiness budget and is passed down to this transport.

The BLE readiness flow includes:

- BLE connection
- MIDI service and characteristic discovery
- pairing/bonding when required
- notification subscription

On platforms without an explicit pairing API, such as iOS and macOS, pairing is triggered by accessing the encrypted MIDI characteristic and failures are surfaced as typed `MidiConnectionException` subclasses from `flutter_midi_command_platform_interface`.
