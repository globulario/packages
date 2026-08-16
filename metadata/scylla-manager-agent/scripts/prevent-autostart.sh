#!/bin/bash
set -euo pipefail

echo "[scylla-manager-agent/prevent-autostart] Blocking service auto-start during dpkg install..."

systemctl stop scylla-manager-agent.service 2>/dev/null || true
systemctl disable scylla-manager-agent.service 2>/dev/null || true

cat > /usr/sbin/policy-rc.d << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

echo "[scylla-manager-agent/prevent-autostart] Auto-start blocked"
