#!/usr/bin/env bash
set -euo pipefail

PKGS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-/tmp/oxigraph-packages}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SPEC="${PKGS_ROOT}/specs/oxigraph_service.yaml"
META="${PKGS_ROOT}/metadata/oxigraph/package.json"
BIN_OUT="${PKGS_ROOT}/bin/oxigraph"

OXIGRAPH_BIN="${OXIGRAPH_BIN:-}"
if [[ -z "$OXIGRAPH_BIN" ]]; then
  if command -v oxigraph >/dev/null 2>&1; then
    OXIGRAPH_BIN="$(command -v oxigraph)"
  else
    echo "oxigraph binary not found. Set OXIGRAPH_BIN=/path/to/oxigraph" >&2
    exit 1
  fi
fi

if [[ ! -x "$OXIGRAPH_BIN" ]]; then
  echo "OXIGRAPH_BIN is not executable: $OXIGRAPH_BIN" >&2
  exit 1
fi

mkdir -p "${PKGS_ROOT}/bin" "${PKGS_ROOT}/metadata/oxigraph/specs"
if [[ "$(readlink -f "$OXIGRAPH_BIN")" != "$(readlink -f "$BIN_OUT")" ]]; then
  install -m 0755 "$OXIGRAPH_BIN" "$BIN_OUT"
fi
cp "$SPEC" "${PKGS_ROOT}/metadata/oxigraph/specs/oxigraph_service.yaml"

SHA="$(sha256sum "$BIN_OUT" | awk '{print $1}')"
python3 - <<PY
import json
from pathlib import Path
p = Path(r'''$META''')
d = json.loads(p.read_text())
d['entrypoint_checksum'] = 'sha256:' + r'''$SHA'''
p.write_text(json.dumps(d, indent=2) + '\n')
PY

ROOT="${WORK_DIR}/oxigraph"
mkdir -p "$ROOT/bin" "$ROOT/specs"
cp "$BIN_OUT" "$ROOT/bin/oxigraph"
cp "$SPEC" "$ROOT/specs/oxigraph_service.yaml"

mkdir -p "$OUT_DIR"
globular pkg build \
  --spec "$ROOT/specs/oxigraph_service.yaml" \
  --root "$ROOT" \
  --version "0.5.9" \
  --publisher "core@globular.io" \
  --platform "linux_amd64" \
  --out "$OUT_DIR" \
  --skip-missing-config=true \
  --skip-missing-systemd=true

echo "oxigraph package built in $OUT_DIR"
