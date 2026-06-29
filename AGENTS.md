# AGENTS.md — Globular Packages Operating Rules

This repository is the package-definition layer for Globular. It is not service
source code and it is not the installer implementation. Changes here affect what
artifacts the platform can publish, install, supervise, and validate.

Before editing, identify which package contract you are touching:

- Package identity: `registry.yaml`, `metadata/*/package.json`
- Install plan: `specs/*.yaml`, `metadata/*/specs/*.yaml`
- Runtime supervision: `metadata/*/systemd/*.service`
- Install hooks: `metadata/*/scripts/*`, `scripts/*`
- Package awareness: `metadata/*/awareness.yaml`, `docs/awareness/*`

Hard rules:

- The canonical package registry is `registry.yaml`. Do not add a second package
  kind list in scripts or docs.
- Package kind must agree across registry, root spec, metadata spec, and
  `metadata/*/package.json`.
- Package name identity uses hyphenated package names. Spec service IDs may use
  underscores, but package directory names and registry names must stay
  hyphenated.
- `entrypoint` in `package.json`, spec executable fields, and systemd `ExecStart`
  must identify the same binary.
- Infrastructure, service, and command packages are not interchangeable.
- Do not hardcode platform release versions into package metadata. Platform
  releases are BOM identity; package versions are package identity.
- Do not add destructive install hooks unless they are guarded, idempotent, and
  explicitly documented in awareness.
- Scylla data wipe patterns require the safety guard to pass.
- Generated or mirrored specs must be kept consistent with source metadata.

Required validation after package metadata changes:

```bash
./scripts/validate-package-metadata.sh --repo-root .
./scripts/check-scylla-postinstall-safety.sh
```

For awareness/manageability changes, also run:

```bash
awg check -strict -input docs/awareness -input docs/intent
awg validate -repo-root . -dir docs/awareness -dir docs/intent
```

