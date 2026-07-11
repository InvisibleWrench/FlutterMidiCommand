## 1.0.3

 - Update a dependency to the latest release.

## 1.0.2

## 1.0.1

 - Update a dependency to the latest release.

## Unreleased
- Fixed Linux connection lifecycle handling, including stale-wrapper disconnects and received-message subscription cleanup.
- Fixed targeted sends so `deviceId` sends only to the requested connected Linux device.
- Added deterministic Linux unit tests for discovery refresh, targeted sends, disconnects, stream teardown, and optional platform APIs.
- Removed stale native Linux C++/CMake scaffold; the package is Dart-only via `dartPluginClass`.
- Documented the current Linux virtual MIDI limitation.

## 1.0.0
- Major release aligned with the federated monorepo architecture.
- Updated to the 1.x platform interface and typed host models.

## 0.3.0
- Updated to Flutter 3.10, Dart 3
- Added error messages for missing functionality

## 0.1.4
Updated to latest platform interface

## 0.1.3
Fixed buffer allocation

## 0.1.2
Isolate port close

## 0.1.1
Fixed notification on device disconnect

## 0.1.0
First release with linux support

## 0.0.1
Initial Linux support
