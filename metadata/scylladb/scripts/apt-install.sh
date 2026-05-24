#!/bin/bash
# apt-install.sh — Install ScyllaDB OS packages from apt.
#
# Runs during Day-1 (node join) when the scylladb wrapper package has no
# bundled .deb files. The join script sets up the apt source and GPG key
# before the workflow runs, so this just needs to apt-get install.
#
# Idempotent: exits immediately if scylla-server is already installed.

set -euo pipefail

if dpkg -s scylla-server >/dev/null 2>&1; then
    echo "[scylladb/apt-install] scylla-server already installed, skipping"
    exit 0
fi

echo "[scylladb/apt-install] scylla-server not installed — installing from apt..."

# Ensure GPG key is present (join script should have set this up already).
if [[ ! -f /etc/apt/keyrings/scylladb.gpg ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://downloads.scylladb.com/deb/ubuntu/scylladb-2025.3.gpg | \
        gpg --dearmor -o /etc/apt/keyrings/scylladb.gpg
    chmod 644 /etc/apt/keyrings/scylladb.gpg
    echo "[scylladb/apt-install] GPG key installed"
fi

# Ensure apt source is present.
if [[ ! -f /etc/apt/sources.list.d/scylladb.list ]]; then
    echo "deb [arch=amd64,arm64 signed-by=/etc/apt/keyrings/scylladb.gpg] https://downloads.scylladb.com/downloads/scylla/deb/debian-ubuntu/scylladb-2025.3 stable main" \
        > /etc/apt/sources.list.d/scylladb.list
    echo "[scylladb/apt-install] apt source configured"
fi

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    scylla scylla-server scylla-conf scylla-cqlsh scylla-python3

echo "[scylladb/apt-install] ScyllaDB installed successfully"
