#!/usr/bin/env bash
# verify-libnss-resolve_test.sh — bounded fakes for the payload verifier.
#
# libnss-resolve carries no entrypoint checksum, so this verifier is the ONLY
# thing standing between "dpkg was invoked" and "the NSS library is really
# installed and wired". If it can pass while evidence is missing, the package
# is back to claiming an install it cannot demonstrate — the failure the
# fabricated bin/ marker used to hide.
#
# Each case fakes dpkg-query on PATH and points the verifier at a temp
# nsswitch.conf, then asserts pass/fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/metadata/libnss-resolve/scripts/verify-libnss-resolve.sh"
PASS=0; FAIL=0

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/lib/aarch64-linux-gnu"
REAL_LIB="${WORK}/lib/aarch64-linux-gnu/libnss_resolve.so.2"
touch "${REAL_LIB}"

# fake dpkg-query: $1 = -W status output ("" => package unknown)
#                  $2 = -L listing      ("" => no files listed)
fake_dpkg() {
    cat > "${WORK}/bin/dpkg-query" <<EOF
#!/bin/sh
case "\$1" in
  -W) [ -n "$1" ] && printf '%s' "$1" || exit 1 ;;
  -L) [ -n "$2" ] && echo "$2" || exit 1 ;;
esac
EOF
    chmod +x "${WORK}/bin/dpkg-query"
}

run_case() { # name expect(pass|fail) status listing hostsline
    local name="$1" expect="$2" status="$3" listing="$4" hosts="$5"
    fake_dpkg "${status}" "${listing}"
    printf 'passwd: files\nhosts: %s\n' "${hosts}" > "${WORK}/nsswitch.conf"
    sed "s#/etc/nsswitch.conf#${WORK}/nsswitch.conf#g" "${SCRIPT}" > "${WORK}/v.sh"
    if PATH="${WORK}/bin:${PATH}" sh "${WORK}/v.sh" >/dev/null 2>&1; then
        got=pass
    else
        got=fail
    fi
    if [ "${got}" = "${expect}" ]; then
        echo "  ok   ${name} (${got})"; PASS=$((PASS+1))
    else
        echo "  FAIL ${name}: expected ${expect}, got ${got}"; FAIL=$((FAIL+1))
    fi
}

echo "== verify-libnss-resolve.sh =="
# Positive: all four pieces of evidence present. Uses a NON-amd64 multiarch
# path to prove the library location is resolved from dpkg, not hardcoded.
run_case "all evidence present (aarch64 multiarch path)" pass "ii " "${REAL_LIB}" "files resolve dns"

run_case "dpkg has no record"            fail ""     "${REAL_LIB}"                 "files resolve dns"
run_case "dpkg not fully installed (iU)" fail "iU "  "${REAL_LIB}"                 "files resolve dns"
run_case "dpkg half-configured (iF)"     fail "iF "  "${REAL_LIB}"                 "files resolve dns"
run_case "no libnss_resolve.so.2 listed" fail "ii "  "${WORK}/lib/README"          "files resolve dns"
run_case "listed library absent on disk" fail "ii "  "${WORK}/lib/gone/libnss_resolve.so.2" "files resolve dns"
run_case "hosts: lacks resolve"          fail "ii "  "${REAL_LIB}"                 "files dns myhostname"
run_case "hosts: has resolveX only"      fail "ii "  "${REAL_LIB}"                 "files resolveX dns"

echo
echo "== configure-nsswitch.sh =="
CFG="${ROOT}/metadata/libnss-resolve/scripts/configure-nsswitch.sh"
cfg_case() { # name inputhosts expecthosts
    printf 'passwd: files\nhosts: %s\n' "$2" > "${WORK}/c.conf"
    if NSSWITCH_CONF="${WORK}/c.conf" sh "${CFG}" >/dev/null 2>&1; then
        got="$(awk '$1=="hosts:"{ $1=""; sub(/^ /,""); print }' "${WORK}/c.conf")"
    else
        got="<failed>"
    fi
    if [ "${got}" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1))
    else echo "  FAIL $1: got '${got}', want '$3'"; FAIL=$((FAIL+1)); fi
}
cfg_case "mdns4 default gets resolve before dns" \
    "files mdns4_minimal [NOTFOUND=return] dns myhostname" \
    "files mdns4_minimal [NOTFOUND=return] resolve dns myhostname"
cfg_case "plain files dns"          "files dns"          "files resolve dns"
cfg_case "no dns entry: appended"   "files myhostname"   "files myhostname resolve"
cfg_case "already wired: unchanged" "files resolve dns"  "files resolve dns"

printf 'passwd: files\nhosts: files dns\n' > "${WORK}/c.conf"
NSSWITCH_CONF="${WORK}/c.conf" sh "${CFG}" >/dev/null 2>&1
NSSWITCH_CONF="${WORK}/c.conf" sh "${CFG}" >/dev/null 2>&1
n="$(awk '$1=="hosts:"{for(i=2;i<=NF;i++) if($i=="resolve") c++} END{print c+0}' "${WORK}/c.conf")"
if [ "${n}" = "1" ]; then echo "  ok   idempotent across two runs"; PASS=$((PASS+1))
else echo "  FAIL idempotence: ${n} resolve entries"; FAIL=$((FAIL+1)); fi

printf 'passwd: files\n' > "${WORK}/c.conf"
if NSSWITCH_CONF="${WORK}/c.conf" sh "${CFG}" >/dev/null 2>&1; then
    echo "  FAIL missing hosts: line silently succeeded"; FAIL=$((FAIL+1))
else echo "  ok   missing hosts: line fails loudly"; PASS=$((PASS+1)); fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
