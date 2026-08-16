#!/bin/sh
# configure-nsswitch.sh — wire the "resolve" NSS method into the hosts: line so
# glibc- and cgo-resolver-based lookups (including Go binaries) route through
# systemd-resolved, which is what actually answers *.globular.internal.
#
# Deterministic and idempotent: after a successful run the hosts: line contains
# the distinct token `resolve` exactly once, whatever the starting layout was.
#
# The previous version only rewrote the line when it matched one specific
# mdns4_minimal default and otherwise did nothing — silently — while still
# exiting 0. On any other base image the package installed "successfully" with
# resolution left unwired. This version handles the general case, preserves
# existing entries and their order, and fails loudly rather than returning
# success having changed nothing.

set -eu

NSSWITCH="${NSSWITCH_CONF:-/etc/nsswitch.conf}"

[ -f "${NSSWITCH}" ] || { echo "configure-nsswitch: ${NSSWITCH} not found" >&2; exit 1; }

grep -q '^hosts:' "${NSSWITCH}" || {
    echo "configure-nsswitch: no hosts: line in ${NSSWITCH}" >&2
    exit 1
}

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

# Insert `resolve` immediately before `dns` when present (resolved should be
# consulted first), else append it. An already-configured line is left
# byte-identical.
awk '
  $1 == "hosts:" {
    for (i = 2; i <= NF; i++) if ($i == "resolve") { print; next }
    line = $1
    inserted = 0
    for (i = 2; i <= NF; i++) {
      if ($i == "dns" && !inserted) { line = line " resolve"; inserted = 1 }
      line = line " " $i
    }
    if (!inserted) line = line " resolve"
    print line
    next
  }
  { print }
' "${NSSWITCH}" > "${tmp}"

# Verify before publishing: never install a hosts: line that lacks the method
# we were asked to add, or that added it more than once.
count="$(awk '$1 == "hosts:" { for (i = 2; i <= NF; i++) if ($i == "resolve") n++ } END { print n + 0 }' "${tmp}")"
[ "${count}" = "1" ] || {
    echo "configure-nsswitch: refusing to install hosts: line with ${count} resolve entries" >&2
    exit 1
}

cat "${tmp}" > "${NSSWITCH}"
echo "configure-nsswitch: OK ($(grep '^hosts:' "${NSSWITCH}"))"
