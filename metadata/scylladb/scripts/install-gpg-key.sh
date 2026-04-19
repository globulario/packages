#!/bin/bash
set -euo pipefail

# Install ScyllaDB GPG key for apt repository verification.
# Idempotent: exits early if the key already exists.

[ -f /etc/apt/keyrings/scylladb.gpg ] && exit 0

mkdir -p /etc/apt/keyrings
curl -fsSL https://downloads.scylladb.com/deb/ubuntu/scylladb-2025.3.gpg | \
  gpg --dearmor -o /etc/apt/keyrings/scylladb.gpg
