#!/usr/bin/env bash
# build-no-entrypoint_test.sh — regression tests for `entrypoint: none`.
#
# libnss-resolve is the first package with no executable of its own: it ships a
# passive NSS plugin library, not a binary. Before this support existed,
# build.sh treated every nonempty entrypoint as a path under bin/, so `none`
# resolved to bin/none, was not found, and the package was silently SKIPPED —
# which is how it came to carry a fabricated marker executable purely so an
# entrypoint checksum could be computed for it.
#
# These tests pin the honest model: a no-entrypoint package builds, ships no
# surrogate binary, and produces no entrypoint checksum, while ordinary
# executable packages keep requiring their real binary.
#
# Usage: GLOBULAR_BIN=/path/to/globular bash scripts/build-no-entrypoint_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOBULAR_BIN="${GLOBULAR_BIN:-globular}"
PKG=libnss-resolve
META="${ROOT}/metadata/${PKG}"
PASS=0; FAIL=0

ok()   { echo "  ok   $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

command -v "${GLOBULAR_BIN}" >/dev/null 2>&1 || [ -x "${GLOBULAR_BIN}" ] || {
    echo "SKIP: globular CLI not available at '${GLOBULAR_BIN}'"; exit 0; }

OUT="$(mktemp -d)"; trap 'rm -rf "${OUT}"' EXIT

echo "== canonical build =="
GLOBULAR_BIN="${GLOBULAR_BIN}" bash "${ROOT}/build.sh" --out "${OUT}" >"${OUT}/build.log" 2>&1
ARCHIVE="$(find "${OUT}" -name "${PKG}_*.tgz" | head -1)"

# 1. entrypoint: none is not skipped.
if [ -n "${ARCHIVE}" ]; then ok "entrypoint: none builds (not skipped)"
else bad "entrypoint: none was skipped — no ${PKG} archive produced"; fi

# 2. no bin/none is required (the build above had none and still succeeded).
if grep -q "SKIP ${PKG}: binary not found at bin/none" "${OUT}/build.log"; then
    bad "build looked for a bin/none file"
else ok "no bin/none required"; fi

if [ -n "${ARCHIVE}" ]; then
    LIST="$(tar tzf "${ARCHIVE}")"
    MANIFEST="$(tar xzf "${ARCHIVE}" -O package.json)"

    # 3. no marker executable is bundled.
    if echo "${LIST}" | grep -qE "^bin/.+"; then
        bad "archive bundles a binary: $(echo "${LIST}" | grep -E '^bin/.+')"
    else ok "no surrogate/marker executable bundled"; fi

    # 4. manifest declares the sentinel.
    check "$(echo "${MANIFEST}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("entrypoint",""))')" \
          "none" "manifest entrypoint == none"

    # 5. manifest carries NO entrypoint checksum.
    if echo "${MANIFEST}" | grep -q entrypoint_checksum; then
        bad "manifest carries an entrypoint_checksum for a package with no executable"
    else ok "manifest has no entrypoint_checksum"; fi

    # 6. the checked-in .deb is included, byte-identical.
    DEB="$(basename "$(find "${META}/debs" -name '*.deb' | head -1)")"
    if echo "${LIST}" | grep -q "debs/${DEB}"; then
        A="$(tar xzf "${ARCHIVE}" -O "debs/${DEB}" | sha256sum | awk '{print $1}')"
        B="$(sha256sum "${META}/debs/${DEB}" | awk '{print $1}')"
        check "${A}" "${B}" "bundled .deb is the checked-in one, byte-identical"
    else bad "checked-in .deb ${DEB} missing from archive"; fi

    # Offline: the canonical build must not have pulled a dependency closure.
    NDEBS="$(echo "${LIST}" | grep -c '^debs/.*\.deb$')"
    check "${NDEBS}" "1" "exactly one .deb bundled (no apt-get download closure)"

    # 7. the verification script is included.
    if echo "${LIST}" | grep -q "scripts/verify-${PKG}.sh"; then
        ok "payload verification script included"
    else bad "verify-${PKG}.sh missing from archive"; fi
fi

# 8. removing the .deb fails the build rather than falling back to the network.
echo "== negative control: missing debs/ =="
mv "${META}/debs" "${OUT}/debs-bak"
OUT2="$(mktemp -d)"
GLOBULAR_BIN="${GLOBULAR_BIN}" bash "${ROOT}/build.sh" --out "${OUT2}" >"${OUT}/build2.log" 2>&1
if find "${OUT2}" -name "${PKG}_*.tgz" | grep -q .; then
    bad "build succeeded without the checked-in .deb (silent apt-get fallback)"
else ok "missing debs/ fails the build"; fi
mv "${OUT}/debs-bak" "${META}/debs"
rm -rf "${OUT2}"

# 9. an ordinary executable package still requires bin/<entrypoint>.
if grep -qE "SKIP [a-z-]+: binary not found at bin/[a-z]" "${OUT}/build.log"; then
    ok "ordinary executable packages still require bin/<entrypoint>"
else bad "no executable package enforced its bin/ requirement"; fi

# 10. existing noop packages retain current behavior (not special-cased here).
if grep -q "SKIP .*binary not found at bin/noop" "${OUT}/build.log"; then
    ok "noop packages unchanged (still skipped, no none-migration)"
else bad "noop package behavior changed"; fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
