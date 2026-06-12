#!/usr/bin/env bash
# validate-package-metadata.sh — build-time package kind/type consistency checker.
#
# Validates that every package's kind is declared consistently across:
#   1. specs/<name>_{service,cmd}.yaml  — metadata.kind (build-time source of truth)
#   2. metadata/<name>/package.json     — "type" field (committed reference copy)
#   3. Known catalog classification     — hard-coded cross-check for cataloged components
#
# Exits 0 on success, 1 on any mismatch.
#
# Usage:
#   ./scripts/validate-package-metadata.sh [--repo-root <path>]
#
# Run from the packages/ repo root or pass --repo-root explicitly.
#
# Requirements: python3 (for YAML parsing), jq or python3 (for JSON parsing)

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SPECS_DIR="$REPO_ROOT/specs"
METADATA_DIR="$REPO_ROOT/metadata"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; SPECS_DIR="$REPO_ROOT/specs"; METADATA_DIR="$REPO_ROOT/metadata"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

ERRORS=0
WARNINGS=0

err() { echo "ERROR $*" >&2; ((ERRORS++)) || true; }
warn() { echo "WARN  $*" >&2; ((WARNINGS++)) || true; }
ok() { echo "OK    $*"; }

# ---------------------------------------------------------------------------
# Catalog: authoritative kind for every known cataloged component.
# Must be kept in sync with component_catalog.go (KindInfrastructure /
# KindWorkload / KindCommand). Infrastructure = infra daemon (no gRPC API to
# the mesh). Service = gRPC workload managed by desired state. Command = CLI tool.
#
# Update this list whenever component_catalog.go changes.
# ---------------------------------------------------------------------------
declare -A CATALOG_KIND=(
  # KindInfrastructure
  [etcd]=infrastructure         [minio]=infrastructure
  [scylladb]=infrastructure     [xds]=infrastructure
  [gateway]=infrastructure      [envoy]=infrastructure
  [prometheus]=infrastructure   [alertmanager]=infrastructure
  [node-exporter]=infrastructure [scylla-manager]=infrastructure
  [scylla-manager-agent]=infrastructure [sidekick]=infrastructure
  [keepalived]=infrastructure

  # KindWorkload → "service" in package.json
  [dns]=service                 [discovery]=service
  [event]=service               [rbac]=service
  [file]=service                [monitoring]=service
  [authentication]=service      [resource]=service
  [persistence]=service         [sql]=service
  [storage]=service             [repository]=service
  [catalog]=service             [search]=service
  [log]=service                 [ldap]=service
  [mail]=service                [blog]=service
  [conversation]=service        [title]=service
  [media]=service               [torrent]=service
  [echo]=service                [backup-manager]=service
  [cluster-controller]=service  [cluster-doctor]=service
  [node-agent]=service          [ai-memory]=service
  [ai-executor]=service         [ai-router]=service
  [ai-watcher]=service          [workflow]=service
  [mcp]=service

  # KindCommand
  [rclone]=command  [restic]=command  [sctool]=command
  [mc]=command      [ffmpeg]=command  [etcdctl]=command
  [sha256sum]=command [yt-dlp]=command [globular-cli]=command
  [claude]=command
)

# ---------------------------------------------------------------------------
# Helper: extract kind from a spec YAML file using python3.
# Falls back to grep if python3 is unavailable.
# ---------------------------------------------------------------------------
spec_kind() {
  local specfile="$1"
  if command -v python3 &>/dev/null; then
    python3 - "$specfile" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    for line in f:
        # Match "  kind: infrastructure" under the metadata block.
        m = re.match(r'^\s{2}kind:\s*(\S+)', line)
        if m:
            print(m.group(1).lower())
            sys.exit(0)
    # Default kind derived from filename.
    import os
    base = os.path.basename(path)
    if base.endswith('_cmd.yaml') or base.endswith('_command.yaml'):
        print("command")
    else:
        print("service")
PYEOF
  else
    local base
    base="$(basename "$specfile")"
    local kind
    kind="$(grep -E '^\s{2}kind:' "$specfile" | head -1 | sed 's/.*kind:\s*//' | tr -d '[:space:]')"
    if [[ -z "$kind" ]]; then
      [[ "$base" == *_cmd.yaml || "$base" == *_command.yaml ]] && echo "command" || echo "service"
    else
      echo "$kind"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Helper: extract type from package.json.
# ---------------------------------------------------------------------------
pkg_type() {
  local jsonfile="$1"
  if command -v jq &>/dev/null; then
    jq -r '.type // empty' "$jsonfile"
  else
    python3 -c "import sys,json; d=json.load(open('$jsonfile')); print(d.get('type',''))"
  fi
}

# ---------------------------------------------------------------------------
# Helper: derive metadata directory name from spec filename.
# "mcp_service.yaml" → "mcp", "etcdctl_cmd.yaml" → "etcdctl"
# "scylla_manager_service.yaml" → "scylla-manager"
# ---------------------------------------------------------------------------
spec_to_pkg_name() {
  local specfile="$1"
  local base
  base="$(basename "$specfile")"
  # Strip extension and known suffixes.
  local name="${base%.yaml}"
  name="${name%_service}"
  name="${name%-service}"
  name="${name%_cmd}"
  name="${name%_command}"
  # Convert underscores to hyphens (canonical package name uses hyphens).
  echo "${name//_/-}"
}

# ---------------------------------------------------------------------------
# Valid kind values.
# ---------------------------------------------------------------------------
valid_kind() {
  local k="$1"
  case "$k" in
    service|infrastructure|command|application) return 0 ;;
  esac
  return 1
}

echo "=== Globular Package Metadata Validator ==="
echo "Specs dir:    $SPECS_DIR"
echo "Metadata dir: $METADATA_DIR"
echo ""

# ---------------------------------------------------------------------------
# Pass 1: Check every spec file.
# ---------------------------------------------------------------------------
echo "--- Pass 1: Spec files ---"
for specfile in "$SPECS_DIR"/*.yaml; do
  [[ -f "$specfile" ]] || continue
  name="$(spec_to_pkg_name "$specfile")"
  kind="$(spec_kind "$specfile")"

  # Validate kind is a known value.
  if ! valid_kind "$kind"; then
    err "spec $specfile: metadata.kind=\"$kind\" is not valid (must be service, infrastructure, command, or application)"
    continue
  fi

  # Find corresponding package.json.
  pkgjson="$METADATA_DIR/$name/package.json"
  if [[ ! -f "$pkgjson" ]]; then
    warn "spec $specfile: no corresponding metadata/$name/package.json — spec kind=$kind cannot be cross-checked"
    continue
  fi

  pkgtype="$(pkg_type "$pkgjson")"
  if [[ -z "$pkgtype" ]]; then
    err "metadata/$name/package.json: missing \"type\" field"
    continue
  fi
  if ! valid_kind "$pkgtype"; then
    err "metadata/$name/package.json: \"type\"=\"$pkgtype\" is not valid"
    continue
  fi

  if [[ "$kind" != "$pkgtype" ]]; then
    err "kind mismatch for $name:
      specs/$(basename "$specfile"):  metadata.kind=$kind  (source: spec = build-time source of truth)
      metadata/$name/package.json:    type=$pkgtype        (source: committed reference — must match spec)
    Fix: change the spec metadata.kind to \"$pkgtype\" OR regenerate package.json from the spec."
  else
    ok "spec/$name: spec.kind=$kind == package.json.type=$pkgtype"
  fi
done

# ---------------------------------------------------------------------------
# Pass 2: Check every package.json against the catalog.
# ---------------------------------------------------------------------------
echo ""
echo "--- Pass 2: Catalog cross-check ---"
for pkgjson in "$METADATA_DIR"/*/package.json; do
  [[ -f "$pkgjson" ]] || continue
  name="$(basename "$(dirname "$pkgjson")")"
  pkgtype="$(pkg_type "$pkgjson")"

  if [[ -z "$pkgtype" ]]; then
    err "metadata/$name/package.json: missing \"type\" field"
    continue
  fi
  if ! valid_kind "$pkgtype"; then
    err "metadata/$name/package.json: \"type\"=\"$pkgtype\" is not valid (must be service, infrastructure, command, or application)"
    continue
  fi

  # If this package is in the catalog, its type must match.
  catalog_k="${CATALOG_KIND[$name]:-}"
  if [[ -n "$catalog_k" ]]; then
    if [[ "$pkgtype" != "$catalog_k" ]]; then
      err "catalog mismatch for $name:
      metadata/$name/package.json:  type=$pkgtype
      component_catalog.go:         kind=$catalog_k
    The catalog is the authoritative runtime classification. Align package.json."
    else
      ok "catalog/$name: package.json.type=$pkgtype matches catalog.kind=$catalog_k"
    fi
  fi
done

# ---------------------------------------------------------------------------
# Pass 3: Check every spec file for catalog agreement.
# ---------------------------------------------------------------------------
echo ""
echo "--- Pass 3: Spec-catalog cross-check ---"
for specfile in "$SPECS_DIR"/*.yaml; do
  [[ -f "$specfile" ]] || continue
  name="$(spec_to_pkg_name "$specfile")"
  kind="$(spec_kind "$specfile")"
  catalog_k="${CATALOG_KIND[$name]:-}"
  if [[ -n "$catalog_k" && "$kind" != "$catalog_k" ]]; then
    err "spec-catalog mismatch for $name:
      specs/$(basename "$specfile"):  metadata.kind=$kind
      component_catalog.go:           kind=$catalog_k
    The catalog is the authoritative runtime classification. The spec metadata.kind must agree."
  fi
done

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
if [[ $ERRORS -gt 0 ]]; then
  echo "FAILED: $ERRORS error(s), $WARNINGS warning(s)"
  exit 1
else
  echo "PASSED: 0 errors, $WARNINGS warning(s)"
  exit 0
fi
