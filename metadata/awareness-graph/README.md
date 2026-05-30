# awareness-graph package

This metadata package integrates `awareness-graph` (source repo:
`/home/dave/Documents/github.com/globulario/awareness-graph`) into the shared
Globular package catalog.

## Build

From the `packages` repo:

```bash
./scripts/build-awareness-graph-package.sh /tmp/awareness-graph-packages
```

This helper will:
- build `awareness-graph` server binary from the source repo
- stage package root with `bin/awareness-graph`, spec, and proto
- run `globular pkg build`

## Outputs

- package artifact: `/tmp/awareness-graph-packages/awareness-graph_0.0.1_linux_amd64.tgz`

## Runtime notes

- service id: `awareness.AwarenessGraphService`
- default port/proxy: `10120` / `10121`
- Oxigraph remains backend/sidecar dependency (`oxigraph_query_url`), not an
  agent-facing API.
- query exposure flags remain locked down:
  - `query_exposed_as_sparql=false`
  - `mcp_query_exposed_by_default=false`
