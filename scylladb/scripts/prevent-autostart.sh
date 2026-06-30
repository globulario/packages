#!/bin/bash
# prevent-autostart.sh — Block dpkg from starting ScyllaDB during package install.
#
# ScyllaDB 2025.3+ uses Raft-based topology. The first start bootstraps an
# irreversible Raft group. If it starts with wrong config (localhost seeds),
# the node becomes a standalone cluster that can never join another.
#
# This script installs a policy-rc.d that tells dpkg "don't start services".
# Must be removed after dpkg completes (see allow-autostart.sh).

set -euo pipefail

echo "[scylladb/prevent-autostart] Blocking service auto-start during dpkg install..."

# Stop ScyllaDB if it's already running (from a previous install).
systemctl stop scylla-server.service 2>/dev/null || true
systemctl disable scylla-server.service 2>/dev/null || true

# policy-rc.d returning 101 tells dpkg/invoke-rc.d not to start services.
cat > /usr/sbin/policy-rc.d << 'EOF'
#!/bin/sh
# Temporary: block service start during ScyllaDB package install.
# Removed by allow-autostart.sh after dpkg completes.
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

echo "[scylladb/prevent-autostart] Auto-start blocked"
