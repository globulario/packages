#!/bin/sh
set -e

# Add the "resolve" NSS method to /etc/nsswitch.conf's hosts: line so glibc-
# and cgo-resolver-based hostname lookups route through systemd-resolved.
# Only touches the mdns4_minimal-style default some base images ship;
# leaves an already-configured hosts: line alone (idempotent — safe to
# re-run on every install).
if grep -q 'mdns4_minimal.*NOTFOUND.*return' /etc/nsswitch.conf; then
  sed -i 's/^hosts:.*/hosts:          files resolve dns myhostname/' /etc/nsswitch.conf
fi
