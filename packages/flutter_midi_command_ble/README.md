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

Configure the transport once per application MIDI session, before reading
`onMidiSetupChanged` or `onMidiDataReceived`. Those getters merge the streams
available when they are read, so a subscription created before BLE is
configured does not later acquire BLE events.

### Throughput and latency

Every BLE write costs at least one connection event: `universal_ble` runs writes
through a single serialized queue and completes each one only from the
platform's write callback, even for writes without response. Two things
therefore decide how fast MIDI leaves the app, and both are on by default.

| Option | Default | Effect |
|---|---|---|
| `useNegotiatedMtu` | `true` | Sizes BLE MIDI packets from the negotiated ATT MTU instead of the 20-byte minimum. |
| `requestHighPerformanceConnection` | `true` | Asks for a ~7.5-15 ms connection interval instead of the OS default of ~30-50 ms. |

A 137-byte SysEx is eight writes at the 23-byte default MTU, two at MTU 96, and
one at MTU 247. Fewer writes means less radio time, less queue pressure and
less battery.

**This does not automatically make a bulk transfer faster.** If the protocol
waits for the peripheral to acknowledge each message, the round trip is usually
dominated by the peripheral, not by the link. Measured against a GEWA piano
firmware transfer: handing a packet to the MIDI stack took ~1.4 ms, and waiting
for the piano's ACK took ~495 ms — so the entire write path was 0.3% of the
per-packet cost, and reducing eight writes to two changed the total transfer
time by nothing measurable.

Before tuning the transport for throughput, measure the split. If the wait
dominates, the lever is the protocol — more payload per acknowledged message,
or a window of more than one unacknowledged message — not the BLE layer.

Turn them off only for a specific reason:

```dart
midi.configureBleTransport(
  UniversalBleMidiTransport(
    // For a peripheral that agrees to a large MTU but mishandles writes above
    // 20 bytes. The symptom is SysEx arriving corrupt or not at all, appearing
    // only after an upgrade to this version.
    useNegotiatedMtu: false,
    // For battery-sensitive apps that do not need low-latency MIDI.
    requestHighPerformanceConnection: false,
  ),
);
```

Both requests are best-effort: a peripheral may refuse the MTU exchange, and
several platforms do not implement a connection priority hint at all. Failures
are swallowed, and the transport falls back to 20-byte packets and whatever
interval the OS chooses.

#### Platform support

| Platform | Packet sizing | Connection priority | Outgoing data path |
|---|---|---|---|
| Android | ATT MTU | supported | this transport |
| Windows | GATT `MaxPduSize` | not supported | this transport |
| Linux | BlueZ MTU | not supported | this transport |
| iOS / macOS | `maximumWriteValueLength` | not supported | **CoreMIDI after handoff** |

**Apple platforms are the important exception.** After a BLE connection
succeeds, `MidiCommand` hands the device over to its CoreMIDI counterpart and
routes `sendData` through the platform backend from then on. Once that handoff
completes, this transport no longer writes the device's MIDI, so neither
`useNegotiatedMtu` nor `requestHighPerformanceConnection` affects it — CoreMIDI
does its own BLE MIDI framing inside the OS, and neither option is exposed.

In practice these options change throughput on Android, Windows and Linux, and
on Apple platforms only for the window before the handoff completes or if no
CoreMIDI counterpart appears. If a transfer is slow on iOS, this is not the
knob to reach for.

### Detecting dropped writes

`sendData` is fire-and-forget, so a write the platform rejects is otherwise
invisible. A transfer that splits a payload across many SysEx messages should
watch for failures and treat any event as a corrupted transfer:

```dart
final failures = midi.onBleWriteFailure?.listen((failure) {
  // Abort and restart the transfer; the peripheral has a hole in its data.
});
```

The transport deliberately keeps sending the remaining packets of a SysEx after
a failed write, because abandoning them mid-message would leave the peripheral
parsing a truncated message. Recovery is the caller's decision.

`onBleWriteFailure` only reports writes this transport made. It is therefore
silent on Apple platforms for any device that has been handed off to CoreMIDI,
which has no equivalent per-write failure signal. Treat the stream as an extra
diagnostic on Android/Windows/Linux, not as a cross-platform integrity check —
an application that needs to know a bulk transfer arrived intact still needs
device-level acknowledgements.

A fixed inter-packet delay is not a substitute for an acknowledgement protocol.
The write queue applies backpressure that `sendData` does not expose, so a timer
tuned against a fire-and-forget stack can outrun the link and build an unbounded
backlog whose packets are still in flight long after the app believes the
transfer finished. Pace bulk transfers on responses from the device.

Subscribe to setup changes before starting discovery, then initialize and scan
explicitly:

```dart
final setupSub = midi.onMidiSetupChanged?.listen((_) async {
  final devices = await midi.devices ?? const <MidiDevice>[];
  // Replace the application's current device snapshot.
});

await midi.startBluetooth();
await midi.waitUntilBluetoothIsInitialized();
if (midi.bluetoothState == BluetoothState.poweredOn) {
  await midi.startScanningForBluetoothDevices();
  final initialDevices = await midi.devices ?? const <MidiDevice>[];
  // Use the initial snapshot; do not wait only for a setup event.
}
```

`startBluetooth()` is idempotent and does not start scanning. A later call can
complete without emitting another `onBluetoothStateChanged` event; that stream
reports transitions and does not replay its current value. Always inspect
`bluetoothState` after initialization.

Scan start and stop are idempotent. On some Android devices, however, stopping
and restarting a BLE scan around connect/disconnect can leave the platform
scanner returning no advertisements until the app process restarts. Prefer an
application/session-level scan owner and avoid route-level stop/restart cycles
around a BLE connection.

`await midi.connectToDevice(device)` completes only when the BLE MIDI path is ready for use. The public `awaitConnectionTimeout` from `MidiCommand.connectToDevice` is treated as a full readiness budget and is passed down to this transport.

The BLE readiness flow includes:

- BLE connection
- MIDI service and characteristic discovery
- notification subscription
- pairing/bonding, and a second subscription attempt, only if the peripheral refused the first

A device is connected when its notifications are flowing, not when the OS has bonded it. BLE MIDI carries no security requirement of its own, and peripherals exist whose MIDI characteristic is notifiable with no bond at all — so the subscription is tried first and a bond is obtained only if the peripheral turns it down for want of an encrypted link. **A peripheral that does not need a bond never shows the user a system pairing dialog.** Bonding up front used to fail the whole connection for such a peripheral, which is worth knowing if you previously worked around that.

A bond is asked for at most once per `connectToDevice`, including across the internal connection retry, so a question the user has already answered is not put to them twice. That holds for the dialog the OS raises by itself as well as the one this transport requests: a bonding attempt that ends without a bond fails the connection with `MidiPairingRejectedException` rather than asking again or reconnecting to try its luck. On Android that is also inferred from a subscription that takes the link down while the device is still unbonded, because the platform only reports a failed bond once per process. Declining the dialog therefore fails the connection promptly, which is the behaviour to expect if you are showing the user a spinner while `connectToDevice` is outstanding. A refusal a bond cannot fix — an unsupported characteristic, a missing `BLUETOOTH_CONNECT` permission, a timeout — is reported as what it is rather than provoking a dialog.

On platforms without an explicit pairing API, such as iOS and macOS, there is no `pair()` to call: bonding is instead provoked by reading the encrypted MIDI characteristic, which this transport now does only once a subscription has been refused. Failures are surfaced as typed `MidiConnectionException` subclasses from `flutter_midi_command_platform_interface`.

On Android the explicit bond is usually not needed even by a peripheral that requires encryption, because the stack bonds without being asked: the subscription is held while the system puts up its own pairing dialog, a bond appears, and the subscription then completes. Measured against one such peripheral, that took about ten seconds of human response time. The escalation above is the fallback for peripherals that answer with a security status instead.

Two consequences worth planning for. `MidiPairingRejectedException` becomes rare, since it is now only reached by a peripheral that both demands a bond and has one refused. And the pairing dialog, wherever it comes from, is now waited on inside the notification-subscription stage rather than a pairing stage — so `awaitConnectionTimeout` (30 s by default) has to leave room for the time a user takes to answer it, and a shorter budget will fail there.

An application that wants a bond regardless — to reach CoreMIDI on Apple, say — can ask for one itself with `UniversalBle.pair(device.id)`; this transport does not own the device's bond state.
