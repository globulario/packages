#!/bin/bash
set -euo pipefail

echo "[scylla-manager/allow-autostart] Removing auto-start block..."

rm -f /usr/sbin/policy-rc.d
systemctl stop scylla-manager.service 2>/dev/null || true
systemctl disable scylla-manager.service 2>/dev/null || true

echo "[scylla-manager/allow-autostart] Auto-start allowed for Globular-managed unit only"
