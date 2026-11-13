#!/usr/bin/env bash
# Copies the Swift API contract into the app.   ./scripts/syncContracts.sh [--check]
# Source: $BILLBOARD_CONTRACTS_ROOT, else ../billboard-backend/contracts (clone billboard-backend next to this repository).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${BILLBOARD_CONTRACTS_ROOT:-}" ]]; then CONTRACTS_ROOT="${BILLBOARD_CONTRACTS_ROOT%/}"
else CONTRACTS_ROOT="${ROOT}/../billboard-backend/contracts"; fi
SRC_SWIFT="${CONTRACTS_ROOT}/generated/swift/UserAPIContractsV1.swift"
DEST_APP="${ROOT}/Billboard/Billboard/Domain/Contracts/UserAPIContractsV1.swift"
[[ -f "${SRC_SWIFT}" ]] || {
  echo "Missing contract source: ${SRC_SWIFT}" >&2
  echo "Clone billboard-backend next to this repository, or set BILLBOARD_CONTRACTS_ROOT to its contracts folder." >&2
  exit 1
}
REV="$(git -C "${CONTRACTS_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ "${1:-}" == "--check" ]]; then
  cmp -s "${SRC_SWIFT}" "${DEST_APP}" && { echo "Swift contract matches ${CONTRACTS_ROOT} @ ${REV}"; exit 0; }
  echo "Swift contract differs from ${CONTRACTS_ROOT} @ ${REV}; run ./scripts/syncContracts.sh" >&2; exit 1
fi
mkdir -p "$(dirname "${DEST_APP}")"; cp "${SRC_SWIFT}" "${DEST_APP}"
echo "Synced Billboard/Billboard/Domain/Contracts/UserAPIContractsV1.swift from ${CONTRACTS_ROOT} @ ${REV}"
