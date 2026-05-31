#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/specs/oxigraph_service.yaml"
META="$ROOT/metadata/oxigraph/package.json"

[ -f "$SPEC" ] || { echo "missing spec: $SPEC" >&2; exit 1; }
[ -f "$META" ] || { echo "missing metadata: $META" >&2; exit 1; }

python3 - <<PY
import json
from pathlib import Path
m = json.loads(Path(r'''$META''').read_text())
assert m["name"] == "oxigraph"
assert m["type"] == "infrastructure"
assert m["entrypoint"] == "bin/oxigraph"
assert m["defaults"]["spec"] == "specs/oxigraph_service.yaml"
rd = m["runtime_defaults"]
assert rd["query_url"] == "http://0.0.0.0:7878/query"
assert rd["store_url"] == "http://0.0.0.0:7878/store?default"
assert rd["tls_termination"] == "external"
print("oxigraph package metadata check: ok")
PY

rg -q "globular-oxigraph.service" "$SPEC"
rg -q "OXIGRAPH_BIND=0.0.0.0:7878" "$SPEC"
rg -F -q 'serve --bind ${OXIGRAPH_BIND}' "$SPEC"

echo "oxigraph spec check: ok"
