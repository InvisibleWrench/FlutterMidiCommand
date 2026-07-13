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
