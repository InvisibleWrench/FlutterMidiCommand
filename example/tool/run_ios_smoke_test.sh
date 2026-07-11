#!/usr/bin/env bash
set -euo pipefail

SMOKE_TEST_PATH="${IOS_SMOKE_TEST_PATH:-integration_test/smoke_test.dart}"
MAX_ATTEMPTS="${IOS_SMOKE_MAX_ATTEMPTS:-2}"
ATTEMPT_TIMEOUT_SECONDS="${IOS_SMOKE_ATTEMPT_TIMEOUT_SECONDS:-600}"

SIMULATOR_ID="${IOS_DEVICE_ID:-}"
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
}

run_smoke_test() {
  flutter test "${SMOKE_TEST_PATH}" \
    -d "${SIMULATOR_ID}" \
    --reporter expanded \
    --timeout 4m &
  local test_pid=$!
  local timed_out_file
  timed_out_file="$(mktemp)"

  (
    sleep "${ATTEMPT_TIMEOUT_SECONDS}"
    if kill -0 "${test_pid}" 2>/dev/null; then
      echo "iOS smoke test exceeded ${ATTEMPT_TIMEOUT_SECONDS}s; terminating it."
      echo timed-out >"${timed_out_file}"
      pkill -TERM -P "${test_pid}" >/dev/null 2>&1 || true
      kill -TERM "${test_pid}" >/dev/null 2>&1 || true
      sleep 10
      pkill -KILL -P "${test_pid}" >/dev/null 2>&1 || true
      kill -KILL "${test_pid}" >/dev/null 2>&1 || true
    fi
  ) &
  local watchdog_pid=$!

  local status=0
  wait "${test_pid}" || status=$?
  kill "${watchdog_pid}" >/dev/null 2>&1 || true
  wait "${watchdog_pid}" 2>/dev/null || true
  if [[ -s "${timed_out_file}" ]]; then
    status=124
  fi
  rm -f "${timed_out_file}"
  return "${status}"
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
