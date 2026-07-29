#!/bin/bash
set -euo pipefail

echo "[scylla-manager-agent/allow-autostart] Removing auto-start block..."

rm -f /usr/sbin/policy-rc.d
systemctl stop scylla-manager-agent.service 2>/dev/null || true
systemctl disable scylla-manager-agent.service 2>/dev/null || true

echo "[scylla-manager-agent/allow-autostart] Auto-start allowed for Globular-managed unit only"
