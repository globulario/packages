#!/bin/sh
# verify-libnss-resolve.sh — prove the real payload landed.
#
# libnss-resolve ships no executable of its own: it is a passive NSS plugin
# library loaded by glibc. The package therefore declares `entrypoint: none`
# and carries NO entrypoint checksum, so there is no binary-identity proof to
# be had for it.
#
# This script supplies the honest alternative — INSTALLATION EVIDENCE. It
# proves the dpkg record exists, that the package owns a libnss_resolve.so.2,
# that the file is really on disk, and that nsswitch actually routes through
# it. That is emphatically NOT executable identity proof: it says "the library
# is installed and wired", never "these bytes are the ones the manifest
# declared". Conflating the two is what the fabricated bin/ marker used to do.
#
# Exits non-zero on any missing evidence, which fails the install step before
# a receipt is finalized.

set -eu

fail() {
    echo "verify-libnss-resolve: FAIL: $*" >&2
    exit 1
}

# 1. dpkg reports the package fully installed.
#    db:Status-Abbrev renders as "ii " (trailing space) on Ubuntu; compare on
#    the trimmed value so the check does not depend on that padding.
status="$(dpkg-query -W -f='${db:Status-Abbrev}' libnss-resolve 2>/dev/null || true)"
status="$(printf '%s' "${status}" | tr -d '[:space:]')"
[ -n "${status}" ] || fail "dpkg has no record of libnss-resolve"
[ "${status}" = "ii" ] || fail "libnss-resolve is not fully installed (dpkg status '${status}')"

# 2. The installed package owns a libnss_resolve.so.2.
#    Resolved from dpkg rather than hardcoding /lib/x86_64-linux-gnu/, which
#    would be a lie on any non-amd64 multiarch layout.
library="$(dpkg-query -L libnss-resolve 2>/dev/null | awk '/\/libnss_resolve\.so\.2$/ { print; exit }' || true)"
[ -n "${library}" ] || fail "dpkg lists no libnss_resolve.so.2 for libnss-resolve"

# 3. That exact file exists on disk. A dpkg record can outlive the payload.
[ -e "${library}" ] || fail "libnss_resolve.so.2 recorded at ${library} but missing on disk"

# 4. nsswitch actually routes hosts lookups through the resolve method.
#    Distinct-token match: a substring test would accept "resolveX" or a
#    commented line.
awk '
  $1 == "hosts:" {
    for (i = 2; i <= NF; i++) {
      if ($i == "resolve") found = 1
    }
  }
  END { exit found ? 0 : 1 }
' /etc/nsswitch.conf || fail "/etc/nsswitch.conf hosts: line does not contain the resolve method"

echo "verify-libnss-resolve: OK (dpkg=ii library=${library} nsswitch=resolve)"
