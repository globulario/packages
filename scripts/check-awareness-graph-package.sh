#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/specs/awareness_graph_service.yaml"
META="$ROOT/metadata/awareness-graph/package.json"
PROTO="$ROOT/metadata/awareness-graph/awareness_graph.proto"

[ -f "$SPEC" ] || { echo "missing spec: $SPEC" >&2; exit 1; }
[ -f "$META" ] || { echo "missing metadata: $META" >&2; exit 1; }
[ -f "$PROTO" ] || { echo "missing proto: $PROTO" >&2; exit 1; }

python3 - <<PY
import json
from pathlib import Path
m = json.loads(Path(r'''$META''').read_text())
assert m["name"] == "awareness-graph"
assert m["service_id"] == "awareness.AwarenessGraphService"
assert m["entrypoint"] == "bin/awareness-graph"
assert m["defaults"]["spec"] == "specs/awareness_graph_service.yaml"
assert m["defaults"]["proto"] == "proto/awareness_graph.proto"
rd = m["runtime_defaults"]
assert rd["port"] == 10120
assert rd["proxy"] == 10121
assert rd["oxigraph_query_url"] == "http://localhost:7878/query"
assert rd["query_exposed_as_sparql"] is False
assert rd["mcp_query_exposed_by_default"] is False
print("awareness-graph package metadata check: ok")
PY

if rg -q "sparql passthrough|raw sparql" "$SPEC"; then
  echo "spec unexpectedly references SPARQL passthrough" >&2
  exit 1
fi

echo "awareness-graph spec check: ok"
