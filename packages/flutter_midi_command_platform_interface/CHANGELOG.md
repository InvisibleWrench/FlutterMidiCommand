## 1.0.0
- Major API cleanup for the federated 1.0 architecture.
- Typed device/port/packet models used across generated Pigeon host contracts.

## 0.4.3
- Merged PR4 from felixdollack

## 0.4.2
- No change

## 0.4.1
- Added `isNetworkSessionEnabled` and `setNetworkSessionEnabled` for controlling Network Sessions on iOS (introduced in FlutterMidiCommand 0.4.15)

## 0.4.0
- Fixed missing future in connectDevice()

## 0.3.4
- Improved bluetooth state handling:
  - Start bluetooth subsystem only when you want, not automatically
  - Allow to retrieve bluetooth state before starting scanning
  - Allow to observe bluetooth state (poweredOn, poweredOff, ...)
  
## 0.3.3
- Fixed device status value on Android

## 0.3.2
- Fixed null warning

## 0.3.1
- Aligned midi ports

## 0.3.0
- Null safety

## 0.2.1
- Removed print.

## 0.2.0
- Initial release.
