#!/usr/bin/env bash
set -euo pipefail

SMOKE_TEST_PATH="${IOS_SMOKE_TEST_PATH:-integration_test/smoke_test.dart}"
MAX_ATTEMPTS="${IOS_SMOKE_MAX_ATTEMPTS:-2}"

SIMULATOR_ID="${IOS_DEVICE_ID:-}"
if [[ -z "${SIMULATOR_ID}" ]]; then
  SIMULATOR_ID="$(
    flutter devices 2>/dev/null |
      awk -F '•' '/ios/ {id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id); print id; exit}'
  )"
fi

if [[ -z "${SIMULATOR_ID}" ]]; then
  SIMULATOR_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ {print $2; exit}')"
fi

if [[ -z "${SIMULATOR_ID}" ]]; then
  echo "No iOS device/simulator found. Set IOS_DEVICE_ID to override."
  exit 1
fi

IS_SIMULATOR=0
if xcrun simctl list devices available | grep -q "${SIMULATOR_ID}"; then
  IS_SIMULATOR=1
fi

boot_target() {
  if [[ "${IS_SIMULATOR}" -eq 0 ]]; then
    return
  fi
  xcrun simctl boot "${SIMULATOR_ID}" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "${SIMULATOR_ID}" -b >/dev/null
  open -a Simulator --args -CurrentDeviceUDID "${SIMULATOR_ID}" >/dev/null 2>&1 || true
}

run_smoke_test() {
  flutter test "${SMOKE_TEST_PATH}" \
    -d "${SIMULATOR_ID}" \
    --reporter expanded \
    --timeout 4m
}

echo "Running iOS smoke test on target: ${SIMULATOR_ID}"
boot_target

attempt=1
until run_smoke_test; do
  if [[ "${attempt}" -ge "${MAX_ATTEMPTS}" ]]; then
    echo "iOS smoke test failed after ${MAX_ATTEMPTS} attempt(s)."
    exit 1
  fi

  echo "iOS smoke attempt ${attempt} failed, retrying with a clean simulator boot..."
  if [[ "${IS_SIMULATOR}" -eq 1 ]]; then
    xcrun simctl shutdown "${SIMULATOR_ID}" >/dev/null 2>&1 || true
    xcrun simctl erase "${SIMULATOR_ID}" >/dev/null 2>&1 || true
  fi
  boot_target
  attempt=$((attempt + 1))
done
