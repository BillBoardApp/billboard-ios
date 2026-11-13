#!/usr/bin/env bash
# Local gate: the checks the repository's CI runs on a pull request
#
#   ./scripts/test.sh              # contract check, UI rules (and their self-test), unit tests, no build warnings
#   ./scripts/test.sh --release    # ...and a Release build for the simulator (catches build-setting mistakes)
#   ./scripts/test.sh --no-tests   # contract check and UI rules (and their self-test) only (no xcodebuild)
#
# Environment:
#   DESTINATION        xcodebuild destination (default: platform=iOS Simulator,name=iPhone 17)
#   DERIVED_DATA_PATH  passed as -derivedDataPath when set (default: Xcode's own DerivedData)
#   SOURCE_PACKAGES_PATH  passed as -clonedSourcePackagesDirPath when set, so several derived-data folders can share
#                      one checkout of the Swift packages (about 4.5 GB each otherwise)
#   RESULTS_DIR        folder that keeps the result bundles (UnitTests.xcresult, Release.xcresult), for example to
#                      export the render tests' attachments; it must not hold them already. Default: a temporary
#                      folder, deleted at the end.
#
# Every step runs even if an earlier one fails; the script exits 1 if any failed. A build warning fails the gate
# (scripts/check-build-warnings.sh reads each build's result bundle); an incremental build only reports warnings in the
# files it compiled, so build clean before a release. Unit tests need no credentials and no network; the signed-in UI
# tests need a project login and are skipped without one (see README, UI tests).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

run_tests=1
run_release=0
for arg in "$@"; do
  case "$arg" in
    --no-tests) run_tests=0 ;;
    --release) run_release=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -n "${RESULTS_DIR:-}" ]]; then
  mkdir -p "${RESULTS_DIR}" || exit 2
  RESULTS="$(cd "${RESULTS_DIR}" && pwd)"
  for bundle in UnitTests.xcresult Release.xcresult; do
    if [[ -e "${RESULTS}/${bundle}" ]]; then
      echo "RESULTS_DIR already holds ${bundle}; move it away or use an empty folder." >&2
      exit 2
    fi
  done
else
  RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/billboard-gate.XXXXXX")"
  trap 'rm -rf "${RESULTS}"' EXIT
fi

failed=()
step() {
  local name="$1"; shift
  echo ""
  echo "==> ${name}"
  if "$@"; then
    echo "--> ${name}: passed"
  else
    echo "--> ${name}: FAILED" >&2
    failed+=("${name}")
  fi
}

xcode() {
  local -a extra=()
  if [[ -n "${DERIVED_DATA_PATH:-}" ]]; then extra+=(-derivedDataPath "${DERIVED_DATA_PATH}"); fi
  if [[ -n "${SOURCE_PACKAGES_PATH:-}" ]]; then extra+=(-clonedSourcePackagesDirPath "${SOURCE_PACKAGES_PATH}"); fi
  if command -v xcpretty >/dev/null 2>&1; then
    # xcpretty stops with "invalid byte sequence in US-ASCII" on the build's non-ASCII output unless the locale is UTF-8.
    xcodebuild -workspace "${ROOT}/BillBoard.xcworkspace" -scheme Billboard ${extra[@]+"${extra[@]}"} "$@" \
      | LC_ALL=en_US.UTF-8 xcpretty
  else
    xcodebuild -workspace "${ROOT}/BillBoard.xcworkspace" -scheme Billboard ${extra[@]+"${extra[@]}"} "$@"
  fi
}

step "Contract matches the backend's contracts" "${ROOT}/scripts/syncContracts.sh" --check
step "UI rules" "${ROOT}/scripts/check-ui-rules.sh"
step "UI rules self-test" "${ROOT}/scripts/check-ui-rules-selftest.sh"

if [[ ${run_tests} -eq 1 ]]; then
  step "Unit tests (${DESTINATION})" xcode -configuration Debug -destination "${DESTINATION}" \
    -resultBundlePath "${RESULTS}/UnitTests.xcresult" -only-testing:BillboardTests -parallel-testing-enabled NO test
  step "No build warnings (unit tests)" "${ROOT}/scripts/check-build-warnings.sh" "${RESULTS}/UnitTests.xcresult"
fi
if [[ ${run_release} -eq 1 ]]; then
  step "Release build (simulator)" xcode -configuration Release -destination "generic/platform=iOS Simulator" \
    -resultBundlePath "${RESULTS}/Release.xcresult" build
  step "No build warnings (Release build)" "${ROOT}/scripts/check-build-warnings.sh" "${RESULTS}/Release.xcresult"
fi

echo ""
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Gate failed: ${failed[*]}" >&2
  exit 1
fi
echo "Gate passed."
