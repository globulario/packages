#!/bin/bash
set -euo pipefail

# Install ScyllaDB GPG key for apt repository verification.
# Idempotent: exits early if the key already exists.

[ -f /etc/apt/keyrings/scylladb.gpg ] && exit 0

mkdir -p /etc/apt/keyrings

# Import via keyserver — the URL-based .gpg download is no longer published
# by ScyllaDB (returns 404). Using the Ubuntu keyserver with the known key ID
# is stable and does not depend on ScyllaDB's CDN layout.
gpg --homedir /tmp --no-default-keyring \
    --keyring /etc/apt/keyrings/scylladb.gpg \
    --keyserver hkp://keyserver.ubuntu.com \
    --recv-keys A43E06657BAC99E3
chmod 644 /etc/apt/keyrings/scylladb.gpg
