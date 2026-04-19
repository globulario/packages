#!/bin/bash
# allow-autostart.sh — Remove the dpkg auto-start block after package install.

set -euo pipefail

echo "[scylladb/allow-autostart] Removing auto-start block..."

rm -f /usr/sbin/policy-rc.d

# Make sure ScyllaDB is NOT running yet — post-install.sh handles the first start.
systemctl stop scylla-server.service 2>/dev/null || true

echo "[scylladb/allow-autostart] Auto-start allowed (ScyllaDB will be started by post-install)"
