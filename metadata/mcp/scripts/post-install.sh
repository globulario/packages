#!/usr/bin/env bash
# post-install.sh — MCP post-install: deploy intent graph nodes.
# Copies docs/intent/*.yaml from the package payload to the system intent dir.
# Idempotent: safe to run on upgrade (new files are added, existing files updated).
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
INTENT_DST="${STATE_DIR}/intent"
INTENT_SRC="${PACKAGE_ROOT:-}/data/intent"

echo "[mcp/post-install] Deploying intent graph nodes..."

if [[ ! -d "${INTENT_SRC}" ]]; then
    echo "[mcp/post-install] WARNING: intent source not found at ${INTENT_SRC} — skipping"
    exit 0
fi

mkdir -p "${INTENT_DST}"
cp -a "${INTENT_SRC}/." "${INTENT_DST}/"
chown -R globular:globular "${INTENT_DST}" 2>/dev/null || true

COUNT=$(ls "${INTENT_DST}"/*.yaml 2>/dev/null | wc -l)
echo "[mcp/post-install] Intent graph: ${COUNT} nodes deployed to ${INTENT_DST}"
