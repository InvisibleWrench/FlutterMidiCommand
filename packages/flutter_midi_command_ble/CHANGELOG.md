## 1.4.0

 - FIX: only peripherals that advertise the MIDI service are listed. `universal_ble` has one app-wide scan and one app-wide `onScanResult` slot, and it calls that slot for every result of whatever scan is running — whoever started it, with whatever filter. An app that also uses `universal_ble` for its own peripherals and runs an unfiltered scan therefore filled `MidiCommand.devices` with headphones, watches and laptops. Discovery now gates on the advertisement itself, asking exactly what `universal_ble`'s own `withServices` filter asks natively, so a result from this transport's own scan cannot be lost. Rejected peripherals are logged once through `logHandler`, and devices already connected or registered via `registerKnownDevice` are never filtered. `requireAdvertisedMidiService` defaults to `!kIsWeb` — the browser's device chooser returns the chosen device with `services` empty — and is exposed for peripherals that do not advertise the service at all. Reported in [#184](https://github.com/InvisibleWrench/FlutterMidiCommand/issues/184).
 - FIX: the host app and the transport can no longer take each other's scan results. Assigning `UniversalBle.onScanResult` after the transport was constructed left the transport with no scan results, and there is no getter to chain to. Scan results now come from `UniversalBle.scanStream`, which fans out to every listener.
 - FIX: pair on demand instead of bonding before subscribing. The connect sequence used to bond first, on the reasonable-sounding theory that a BLE MIDI characteristic requires an encrypted link. The MMA specification requires no such thing, and peripherals exist whose MIDI characteristic is notifiable with no bond at all — one accepts Android's bonding request, never completes it, and then carries MIDI and SysEx perfectly over the unbonded link. Bonding first therefore turned a peripheral that worked into one that could not be connected at all, and cost every other peripheral a system pairing dialog it did not need. The subscription is now the probe and the bond is the fallback: subscribe first, escalate only when the peripheral turns the subscription down for want of an encrypted link, then try once more. Readiness means "notifications are flowing" rather than "the device is bonded". A bond is asked for at most once per connect. On Apple and web, where there is no `pair()` to escalate to, the read of the encrypted characteristic that makes the OS start "Just Works" pairing is kept and merely deferred to the point where the peripheral has asked for it.
 - FIX: declining a pairing dialog fails the connection promptly with `MidiPairingRejectedException` instead of raising the dialog again. Android bonds of its own accord when a subscription needs an encrypted link, so a decline arrives as a failed CCCD write that looks exactly like a peripheral asking for a bond. `universal_ble` publishes a failed bond only once per process — it de-duplicates against a map that is never cleared — so waiting to be told does not work past the first decline. The retry decision now reads the failure instead: a subscription failing with `deviceDisconnected` on a still-unbonded device is the shape a declined dialog arrives in, and is not retried. A failure carrying a GATT status instead is still a transient fault and still retried, as is a drop on a device that is already bonded, which is what recovers Android dropping the link behind a successful `createBond`. The cost is narrow and chosen: a peripheral that needs no bond and whose link genuinely dies during the subscription loses its one automatic retry and is reported as a refused bond rather than as the drop it was.
 - FIX: a connect refused by a peripheral that is still waking up now succeeds. A peripheral powered on moments earlier refuses `connect` with Android's generic `GATT_ERROR` until its radio is ready, and the single fixed 500 ms retry was too early for it — both attempts failed half a second apart where an attempt two and a half seconds in succeeded, so the user had to tap connect again. The delay is now a schedule, 500 ms then 2 s. The classification that decides whether a failure is retryable at all is untouched, and a declined or discarded bond still stops the loop outright. A peripheral that is genuinely absent now takes the sum of the delays before failing, kept short enough to stay inside a default `awaitConnectionTimeout`.
 - FEAT: peripherals that have stopped advertising are dropped from the discovery list. A peripheral switched off or carried out of range says nothing, and `MidiDevice.visible` was assigned true in five places and false nowhere, so it stuck in `devices` until it happened to be connected and disconnected again. While a scan is running, a peripheral with no sighting inside `hideUnseenPeripheralsAfter` is now hidden — 10 s by default, `null` keeps every peripheral ever seen. Hidden rather than removed, so the `MidiDevice` an application holds stays the same object when the peripheral comes back. `MidiSetupChange.deviceDisappeared` is emitted once per sweep. Aging runs only while scanning, never touches a peripheral that is connected or on its way there, and leaves a `registerKnownDevice` peripheral that has never been seen alone — which is what keeps bonded CoreMIDI peripherals on Apple unaffected.
 - FEAT: incoming framing this transport cannot use is reported instead of silently losing messages. A SysEx whose closing `0xF7` arrives with no timestamp byte ahead of it is lost: the specification requires that timestamp, so the parser reads the terminator as one and the message is never completed. `0xF7` is also a legal timestamp value (`0x80 | 0x77`), so the two cannot be told apart with certainty and nothing is parsed differently — but `BleMidiFramer` now takes an optional `onFramingWarning`, which the transport wires to `logHandler`, so the condition is one log line instead of an investigation. Reported only where a timestamp byte was consumed with nothing following it and a SysEx was open; ordinary truncation stays silent.
 - Update the platform interface dependency constraint to `^1.4.0`.

## 1.3.0

 - FIX: resolve running status, so a device that sends a status byte once and then only data bytes no longer produces duplicated and lost messages. A keyboard sending `90 3C 64 40 7F` now delivers two Note Ons rather than repeating the first and dropping the second, and the missed Note Off that left notes sounding is gone. The BLE parser was a single nine-state machine that conflated BLE framing with MIDI assembly and never cleared its assembly buffer, so every further data byte re-emitted a longer packet. It is now two stages: `BleMidiFramer` for the transport's framing and `MidiMessageSplitter` for MIDI assembly. Reported in [#179](https://github.com/InvisibleWrench/FlutterMidiCommand/issues/179).
 - FIX: running status survives a notification boundary. A run continued in the next BLE packet used to arrive as `[0x00, data]`.
 - FIX: a System Real-Time byte arriving mid-message no longer destroys the note being assembled.
 - FIX: `F1`, `F2` and `F3` are sized correctly, instead of all being treated as single-byte messages.
 - FIX: a SysEx the device never terminates no longer latches the parser shut and swallows every later message.
 - FIX: parser state is cleared on disconnect, so a partial message cannot bleed into the next connection.
 - BREAKING BEHAVIOUR: a System Real-Time byte arriving inside a SysEx is now delivered as its own packet rather than dropped, converging BLE with the Android and Darwin transports.
 - Update the platform interface dependency constraint to `^1.3.0`.

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
