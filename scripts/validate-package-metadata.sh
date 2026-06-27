#!/usr/bin/env bash
# validate-package-metadata.sh — SHIM (kept for backward compatibility).
#
# The original script read a top-level specs/ directory that was removed in the
# 2026-06 source-of-truth consolidation, so its spec/kind passes silently became
# no-ops — which is exactly how the mcp "mcp" vs "mcp_server" binary drift shipped
# undetected. It is replaced by validate-package-identity.py, which checks BOTH
# kind AND binary name across registry.yaml / package.json / spec / systemd unit,
# with registry.yaml (cross-checked against component_catalog.go) as the authority.
#
# This shim delegates so any existing caller (CI, Makefiles) gets a real check.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${HERE}/validate-package-identity.py" "$@"
