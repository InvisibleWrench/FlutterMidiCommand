#!/usr/bin/env bash
# Compiles the darwin plugin sources and runs its Swift unit tests.
#
# `swift package describe` only reads Package.swift, so a Swift syntax or type
# error in the plugin used to pass this job and surface much later in the
# example app build. The sources import Flutter/FlutterMacOS, which plain
# SwiftPM cannot resolve, so point the compiler at the engine frameworks that
# ship with the Flutter SDK.
set -euo pipefail

PACKAGE_PATH="packages/flutter_midi_command_darwin/darwin/flutter_midi_command_darwin"
IOS_DEPLOYMENT_TARGET="13.1"

if [[ -z "${FLUTTER_ROOT:-}" ]]; then
  FLUTTER_BIN="$(command -v flutter || true)"
  if [[ -z "${FLUTTER_BIN}" ]]; then
    echo "flutter not found on PATH. Set FLUTTER_ROOT to the Flutter SDK." >&2
    exit 1
  fi
  FLUTTER_ROOT="$(cd "$(dirname "$(dirname "$(readlink -f "${FLUTTER_BIN}" 2>/dev/null || echo "${FLUTTER_BIN}")")")" && pwd)"
fi

# The engine frameworks are downloaded on demand, so a clean checkout may not
# have them yet.
flutter precache --ios --macos >/dev/null

ENGINE_DIR="${FLUTTER_ROOT}/bin/cache/artifacts/engine"

find_slice() {
  # $1: xcframework name, $2: slice prefix. The artifacts directory is named
  # for the host toolchain, not the runner architecture, so search for it.
  local xcframework slice
  xcframework="$(find "${ENGINE_DIR}" -maxdepth 2 -type d -name "$1" | head -1)"
  if [[ -z "${xcframework}" ]]; then
    echo "Could not find $1 under ${ENGINE_DIR}." >&2
    exit 1
  fi
  slice="$(find "${xcframework}" -maxdepth 1 -type d -name "$2" | head -1)"
  if [[ -z "${slice}" ]]; then
    echo "Could not find a $2 slice in ${xcframework}." >&2
    exit 1
  fi
  echo "${slice}"
}

MACOS_FRAMEWORKS="$(find_slice FlutterMacOS.xcframework 'macos-*')"
# The device slice, so the build covers the same configuration as a release
# app. The simulator slice would compile the same `#if os(iOS)` sources.
IOS_FRAMEWORKS="$(find_slice Flutter.xcframework 'ios-arm64')"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

echo "==> Package manifest"
swift package --package-path "${PACKAGE_PATH}" describe >/dev/null

echo "==> Compiling for macOS"
swift build \
  --package-path "${PACKAGE_PATH}" \
  -Xswiftc -F -Xswiftc "${MACOS_FRAMEWORKS}"

# Built separately because the plugin's network session, BLE handoff and
# lifecycle code lives behind `#if os(iOS)` and is invisible to the macOS build.
echo "==> Compiling for iOS"
swift build \
  --package-path "${PACKAGE_PATH}" \
  --scratch-path "${PACKAGE_PATH}/.build-ios" \
  --triple "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" \
  -Xswiftc -sdk -Xswiftc "${IOS_SDK}" \
  -Xswiftc -F -Xswiftc "${IOS_FRAMEWORKS}" \
  -Xcc -isysroot -Xcc "${IOS_SDK}" \
  -Xcc -F -Xcc "${IOS_FRAMEWORKS}"

echo "==> Swift unit tests"
swift build \
  --build-tests \
  --package-path "${PACKAGE_PATH}" \
  -Xswiftc -F -Xswiftc "${MACOS_FRAMEWORKS}" \
  -Xlinker -F -Xlinker "${MACOS_FRAMEWORKS}" \
  -Xlinker -rpath -Xlinker "${MACOS_FRAMEWORKS}"

TEST_BUNDLE="$(find "${PACKAGE_PATH}/.build" -maxdepth 4 -name '*PackageTests.xctest' | head -1)"
if [[ -z "${TEST_BUNDLE}" ]]; then
  echo "Could not find the built test bundle." >&2
  exit 1
fi

# `swift test` cannot launch the bundle without the engine framework on the
# dynamic loader path, so run it directly. xctest reports on stderr, which melos
# labels as an error even on a passing run; fold it into stdout to keep CI logs
# readable.
DYLD_FRAMEWORK_PATH="${MACOS_FRAMEWORKS}" xcrun xctest "${TEST_BUNDLE}" 2>&1
