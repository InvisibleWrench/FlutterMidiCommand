## 1.2.0

 - Bump "flutter_midi_command_ble" to `1.2.0` and update the platform interface dependency constraint to `^1.2.0`.

## 1.1.2

 - FIX: treat `deviceDisconnected` during the connection sequence as a transient link failure and retry it. universal_ble fails every in-flight GATT operation with this code when an established connection is torn down, so a link that dropped with service discovery or subscription pending reported it rather than a GATT status and was never retried — 1.1.1 covered the same failure only where Android named it as a GATT status. Unlike a GATT status it cannot arise from a peripheral that was never reachable — there has to have been a connection to lose — so it is the least ambiguous of the three signals, and it applies on every platform rather than only Android.
 - Update the platform interface dependency constraint to `^1.1.2`.

## 1.1.1

 - FIX: extend the transient `GATT_ERROR` retry to cover the whole connection sequence, not just the link. 1.0.9 retried a connect that failed outright, but the Android stack can also bring the link up and then drop it part-way through the handshake — most often when reconnecting shortly after a disconnect, before it has settled. That surfaces as a failed service discovery or notification subscription rather than a failed connect, so it was never retried and the attempt was reported as a hard failure.
 - FIX: recognise a `GATT_ERROR` reported against a specific GATT operation. Android names such a failure after the operation ("Failed to update subscription state") and carries the status only in `details`, so matching on the `Unknown Error 133` message missed it. Classification now reads `details` and looks through this package's own per-stage exception wrappers, which also means a peripheral that discards its pairing during a later stage is still surfaced as `MidiPairingInfoRemovedException`. The `details` reading applies only on Android: GATT status codes are an Android concept, and Apple puts the raw `NSError` code in that field, where 133 is `0x85` — inside `CBATTError`'s application-defined range and unrelated.
 - FIX: skip the connection priority reset on teardown when the priority was never raised. A failed connection attempt has nothing to hand back, and asking logged a confusing `deviceNotFound` refusal for a device that was already gone.
 - FIX: absorb the failure from `stopScan` instead of dropping the future. Android rejects a stop once the adapter has been switched off — an ordinary thing for a user to do mid-scan — and both call sites are `void`, so the rejection had no listener and reached the host application's zone handler, where it was reported as a crash for a state the application already handles.
 - Update the platform interface dependency constraint to `^1.1.1`.

## 1.1.0

 - FIX: serialize writes per device so overlapping sends cannot interleave their BLE MIDI packets. A SysEx larger than one packet is written as several that the peripheral reassembles statefully, and `sendData` did not await the resulting writes — so a second SysEx issued before the first had drained had its packets interleaved with it in universal_ble's shared queue, and the peripheral reassembled one message out of two. Silent corruption, worse the faster the application sends, and the likely cause of bulk SysEx transfers that fail partway through with no error from the BLE layer.
 - FEAT: add `sendDataAwaitingDelivery`, which completes once the data has actually been written rather than merely queued. Lets a bulk transfer pace against the link instead of guessing an inter-packet delay; too short a guess previously queued messages behind each other, which is what triggered the interleaving above.
 - FEAT: report the BLE command queue depth through `logHandler` when writes back up behind the link, so an application can tell whether its configured pacing is real.
 - FEAT: size outgoing BLE MIDI packets from the negotiated ATT MTU instead of the fixed 20-byte minimum. `requestMtu` already negotiated 247 and discarded the result; the value is now kept as `mtu - 3`, which is the correct write size on both Android (ATT MTU) and Apple (`maximumWriteValueLength(.withoutResponse) + 3`). On a peripheral negotiating MTU 96 this takes a 137-byte SysEx from eight writes to two. Because universal_ble serializes writes through one queue and completes each only from the platform write callback, every packet costs a connection event, so this reduces radio time and queue pressure. It does **not** by itself make a request/response transfer faster: measured against a GEWA piano, the write path is ~1.4 ms of a ~495 ms per-packet round trip, the rest being the peripheral's own turnaround. Controlled by the new `useNegotiatedMtu` flag (default `true`).
 - FEAT: request `BleConnectionPriority.highPerformance` after the MIDI path is live, and `balanced` before disconnecting, for a ~7.5-15 ms connection interval instead of the OS default of ~30-50 ms. This is a latency improvement for ordinary MIDI traffic. Only Android implements the hint; elsewhere the request fails and is ignored. Controlled by the new `requestHighPerformanceConnection` flag (default `true`).
 - FEAT: report writes the platform rejected on `onWriteFailure`. `_sendBytes` previously discarded every error, so a dropped packet was invisible. The transport still sends the remaining packets of a SysEx after a failure — abandoning them mid-message would leave the peripheral parsing a truncated message — but callers can now detect the corruption.
 - FIX: always emit the BLE MIDI timestamp byte before the closing `0xF7`. When the remaining SysEx body was exactly `packetSize - 1` bytes the terminator went out unframed, which affected 15 message lengths in the first 300. SysEx chunking now lives in a pure `buildBleMidiSysExPackets` function covered by a round-trip test against the receive parser.
 - DOCS: document that these options only apply where this transport carries the data. On iOS and macOS `MidiCommand` hands a connected device over to CoreMIDI, which then owns the write path, so neither option affects it and `onWriteFailure` is silent for handed-off devices.
 - Update the platform interface dependency constraint to `^1.1.0`.

## 1.0.9

 - FIX: move MTU negotiation to the end of the connection sequence, after service discovery, pairing and notification subscription, with its own 2 s cap. It previously ran from the connection callback and, since universal_ble shares one command queue, blocked service discovery for up to the 10 s global timeout — long enough for Android to drop the link with `GATT_ERROR` 133 (`Unknown Error 133`). The MTU exchange is opportunistic: writes stay at the 20-byte BLE MIDI packet size and Apple manages the MTU itself.
 - FIX: retry the BLE link once, after a short settle, when a connection fails with a transient Android `GATT_ERROR` 133.
 - FIX: keep a device in the transport cache when a connection attempt is retried, so the disconnect reported by the failed attempt cannot leave incoming notifications with nothing to resolve to.
 - Update the platform interface dependency constraint to `^1.0.9`.

## 1.0.8

 - Update `universal_ble` to `^2.1.1` for `ConnectionPlatformConfig` API compatibility.
 - Update the platform interface dependency constraint to `^1.0.8`.

## 1.0.7

 - Bump "flutter_midi_command_ble" to `1.0.7` and update the platform interface dependency constraint.

## 1.0.6

 - FIX(ble): map the universal_ble "Peer removed pairing information" error (iOS `CBErrorPeerRemovedPairingInformation`) to a typed `MidiPairingInfoRemovedException`, best-effort clearing the stale bond so a later reconnect can re-pair, instead of leaking a raw `UniversalBleException`.

## 1.0.5

 - FIX(ble): strip the BLE timestamp byte from received SysEx so SysEx round-trips on Android/Linux/Windows/Web (was corrupting the payload before 0xF7).
 - FIX(ble): make scan start/stop idempotent to avoid redundant OS scan calls that can desync the Android LE scanner. Note the known Android limitation below.
 - KNOWN ISSUE (Android): after a BLE MIDI connect+disconnect, a further scan may return no results until the app process is restarted, due to an upstream universal_ble/Android LE-scanner registration bug (reused ScanCallback). See README.

## 1.0.4

 - **FIX**(ci): track pubspec_overrides.yaml so melos bootstrap works on clean checkouts.
 - **FIX**(ble): hide registered devices until rediscovered.
 - **FIX**(ble): remove stale BLE devices on disconnect.
 - **FIX**: await BLE MIDI readiness in connectToDevice.
 - **FIX**: bluetooth discovery with latest Universal_ble.
 - **FIX**: subscribe to BLE MIDI notifications on platforms without a pairing.
 - **FEAT**(ble): bundle Android permissions and document platform setup.

## 1.0.3

 - **FIX**(ble): hide registered devices until rediscovered.
 - **FIX**(ble): remove stale BLE devices on disconnect.
 - **FIX**: await BLE MIDI readiness in connectToDevice.
 - **FIX**: bluetooth discovery with latest Universal_ble.
 - **FIX**: subscribe to BLE MIDI notifications on platforms without a pairing.

## 1.0.2

 - N

## 1.0.1

 - Update a dependency to the latest release.

## 1.0.0

- Updated the shared BLE transport and tests for the `universal_ble` 2.x API.
- Resolved Windows example build issues caused by deprecated coroutine headers in older `universal_ble` releases.

## 1.0.0

- Initial shared BLE transport release for `flutter_midi_command`.
- BLE transport implemented in Dart via `universal_ble`.
