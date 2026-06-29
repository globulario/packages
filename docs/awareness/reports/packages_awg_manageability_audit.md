# Packages AWG Manageability Audit

Date: 2026-06-29

Scope:
- Repository: `packages`
- Worktree: `/tmp/packages-awg`
- AWG source: `/tmp/awg-postmerge`

## Extracted Operating Model

The packages repository owns the artifact-definition layer for Globular:
- `registry.yaml` is the package registry and package-kind authority.
- `metadata/*/package.json` carries package identity and descriptor fields.
- `specs/*.yaml` and `metadata/*/specs/*.yaml` describe install plans.
- `metadata/*/systemd/*.service` describes runtime supervision.
- `metadata/*/scripts/*` and `scripts/*` are privileged package hooks.

## Authored Awareness Artifacts

Added:
- `AGENTS.md`
- `docs/awareness/namespaces.yaml`
- `docs/awareness/high_risk_files.yaml`
- `docs/awareness/authority_rules.yaml`
- `docs/awareness/invariants.yaml`
- `docs/awareness/forbidden_fixes.yaml`
- `docs/awareness/failure_modes.yaml`
- `docs/intent/*.yaml`

## Baseline Validation

Existing package gates on clean `origin/main`:
- `./scripts/validate-package-metadata.sh --repo-root /tmp/packages-awg`
- `./scripts/check-scylla-postinstall-safety.sh`
- `awg check -strict -input /tmp/packages-awg/docs/awareness -input /tmp/packages-awg/docs/intent`
- `awg validate -repo-root /tmp/packages-awg -dir /tmp/packages-awg/docs/awareness -dir /tmp/packages-awg/docs/intent -ag-repo /tmp/awg-postmerge`
- `awg bootstrap --repo /tmp/packages-awg -check -skip-history`
- `awg repo-eval -repo /tmp/packages-awg -ag-repo /tmp/awg-postmerge -services-repo /tmp/services-audit-master`

Baseline inventory:
- metadata package directories: 56
- root package specs: 56

Repo-eval posture:
- overall: strong, 100/100, high confidence
- graph integrity: 100/100
- awareness coverage: 100/100
- invariant/test alignment: 100/100 (0 of 6 critical/high invariants missing governing tests)
- contract posture: 100/100 (4 found, 0 proposal-only, 0 unknown)
- architecture drift: 100/100

## Follow-up Audit Repair

Re-audit after AWG master support found two concrete drift issues:
- generated awareness output was stale after AWG began detecting
  `scripts/validate-package-identity.py`
- several root `specs/*.yaml` files differed from their
  `metadata/<package>/specs/*.yaml` mirrors, and `codex` had a metadata-local
  spec without the corresponding root spec

Repairs:
- refreshed AWG generated files
- synced root specs from package-local specs
- added `specs/codex_cmd.yaml`
- hardened `scripts/validate-package-identity.py` so missing root specs and
  root/metadata-local spec mirror drift now fail the package identity gate
