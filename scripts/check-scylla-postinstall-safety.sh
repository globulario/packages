#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "${ROOT_DIR}/scripts/scylladb/post-install.sh"
  "${ROOT_DIR}/metadata/scylladb/scripts/post-install.sh"
)

fail() {
  echo "[scylla-safety-guard] ERROR: $*" >&2
  exit 1
}

for file in "${FILES[@]}"; do
  [[ -f "${file}" ]] || fail "missing file: ${file}"

  if rg -n "rm -rf /var/lib/scylla|rm -rf /var/lib/scylla/data" "${file}" >/dev/null; then
    if ! rg -n "FORCE_SCYLLA_REINIT" "${file}" >/dev/null; then
      fail "unguarded Scylla data deletion in ${file} (missing FORCE_SCYLLA_REINIT gate)"
    fi
    if ! rg -n "I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED" "${file}" >/dev/null; then
      fail "unguarded Scylla data deletion in ${file} (missing dual-confirmation gate)"
    fi
  fi
done

echo "[scylla-safety-guard] OK: no unguarded Scylla data wipe patterns found"
