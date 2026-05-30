#!/usr/bin/env bash
set -euo pipefail

PKGS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AW_ROOT="${AWARENESS_GRAPH_REPO:-/home/dave/Documents/github.com/globulario/awareness-graph}"
OUT_DIR="${1:-/tmp/awareness-graph-packages}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

SPEC="${PKGS_ROOT}/specs/awareness_graph_service.yaml"
META="${PKGS_ROOT}/metadata/awareness-graph/package.json"
PROTO_SRC="${AW_ROOT}/proto/awareness_graph.proto"
BIN_OUT="${PKGS_ROOT}/bin/awareness-graph"

if [[ ! -d "$AW_ROOT" ]]; then
  echo "awareness-graph repo not found at $AW_ROOT" >&2
  exit 1
fi

mkdir -p "${PKGS_ROOT}/bin"
go -C "$AW_ROOT" build -o "$BIN_OUT" ./golang/server

SHA="$(sha256sum "$BIN_OUT" | awk '{print $1}')"
python3 - <<PY
import json
from pathlib import Path
p = Path(r'''$META''')
d = json.loads(p.read_text())
d['entrypoint_checksum'] = 'sha256:' + r'''$SHA'''
p.write_text(json.dumps(d, indent=2) + '\n')
PY

ROOT="${WORK_DIR}/awareness-graph"
mkdir -p "$ROOT/bin" "$ROOT/specs" "$ROOT/proto"
cp "$BIN_OUT" "$ROOT/bin/awareness-graph"
cp "$SPEC" "$ROOT/specs/awareness_graph_service.yaml"
cp "$PROTO_SRC" "$ROOT/proto/awareness_graph.proto"

mkdir -p "$OUT_DIR"
globular pkg build \
  --spec "$ROOT/specs/awareness_graph_service.yaml" \
  --root "$ROOT" \
  --version "0.0.4" \
  --publisher "core@globular.io" \
  --platform "linux_amd64" \
  --out "$OUT_DIR" \
  --skip-missing-config=true \
  --skip-missing-systemd=true

echo "awareness-graph package built in $OUT_DIR"
