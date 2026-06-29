#!/usr/bin/env bash
set -euo pipefail

SMOKE_TEST_PATH="${ANDROID_SMOKE_TEST_PATH:-integration_test/smoke_test.dart}"
MAX_ATTEMPTS="${ANDROID_SMOKE_MAX_ATTEMPTS:-2}"
DEVICE_ID="${ANDROID_DEVICE_ID:-}"

if [[ -z "${DEVICE_ID}" ]]; then
  DEVICE_ID="$(
    adb devices | awk '/\tdevice$/ {print $1; exit}'
  )"
fi

if [[ -z "${DEVICE_ID}" ]]; then
  DEVICE_ID="emulator-5554"
fi

wait_for_device_ready() {
  adb -s "${DEVICE_ID}" wait-for-device
  local boot_completed=""
  local retries=90
  while [[ "${retries}" -gt 0 ]]; do
    boot_completed="$(adb -s "${DEVICE_ID}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
    if [[ "${boot_completed}" == "1" ]]; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done
  if [[ "${boot_completed}" != "1" ]]; then
    echo "Android device did not report sys.boot_completed=1 in time."
    return 1
  fi
  adb -s "${DEVICE_ID}" shell input keyevent 82 >/dev/null 2>&1 || true
}

run_smoke_test() {
  flutter test "${SMOKE_TEST_PATH}" \
    -d "${DEVICE_ID}" \
    --reporter expanded \
    --timeout 4m
}

echo "Running Android smoke test on device: ${DEVICE_ID}"
wait_for_device_ready

attempt=1
until run_smoke_test; do
  if [[ "${attempt}" -ge "${MAX_ATTEMPTS}" ]]; then
    echo "Android smoke test failed after ${MAX_ATTEMPTS} attempt(s)."
    exit 1
  fi

  echo "Android smoke attempt ${attempt} failed, restarting adb and retrying..."
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null 2>&1 || true
  wait_for_device_ready
  attempt=$((attempt + 1))
done
