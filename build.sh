#!/usr/bin/env bash
# build.sh — Build all infrastructure packages from metadata/<name>/ + bin/.
#
# Usage (from packages/ dir):
#   bash build.sh --out <output-dir>
#
# SOURCE OF TRUTH: metadata/<name>/ is the single home for every package's spec,
# scripts, and data. There is no top-level specs/ directory — it was removed in
# the 2026-06 source-of-truth consolidation because duplicate copies drifted and
# fixes silently landed in the copy the build did NOT read. Edit specs ONLY under
# metadata/<name>/specs/.
#
# For each spec in metadata/*/specs/, assembles a payload root:
#   <tmpdir>/bin/<binary>     — copied from bin/ (pre-built by build-all-packages.sh)
#   <tmpdir>/specs/           — from metadata/<name>/specs/<file>
#   <tmpdir>/data/            — from metadata/<name>/data/ (if present)
#
# Scripts are passed via --scripts-dir metadata/<name>/scripts/ (not bundled in root).
#
# The GLOBULAR_BIN env var overrides the globular CLI path.
set -euo pipefail

PKGS_ROOT="$(cd "$(dirname "$0")" && pwd)"
GLOBULAR="${GLOBULAR_BIN:-globular}"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${OUT_DIR}" ]]; then
    echo "Usage: $0 --out <output-dir>" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

# Identity gate: every package's binary name + kind MUST agree across registry.yaml,
# package.json, the spec, and the systemd unit before a single package is built.
# This is the guard against the recurring mcp "mcp" vs "mcp_server" drift (fixed by
# hand 5+ times, last re-broken by the 2026-06 spec consolidation). Fail loud, never ship.
echo "→ Validating package identity (registry.yaml is authority)..."
python3 "${PKGS_ROOT}/scripts/validate-package-identity.py" --repo-root "${PKGS_ROOT}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

PASS=0
FAIL=0

build_one() {
    local spec="$1"
    local spec_file
    spec_file="$(basename "${spec}")"

    # Spec path is metadata/<name>/specs/<file>; the package name is the metadata
    # dir itself (already the canonical hyphenated name — no filename munging).
    local meta name
    meta="$(cd "$(dirname "${spec}")/.." && pwd)"
    name="$(basename "${meta}")"
    if [[ ! -d "${meta}" ]]; then
        echo "  SKIP ${name}: no metadata dir"
        return 0
    fi

    # Read binary entrypoint from spec metadata.
    local entrypoint
    entrypoint="$(sed -n '/^metadata:/,/^[^ ]/{ s/^[[:space:]]\{1,\}entrypoint:[[:space:]]*//p; }' "${spec}" | \
                  head -1 | tr -d '"' | tr -d "'")"
    if [[ -z "${entrypoint}" ]]; then
        echo "  SKIP ${name}: no entrypoint in spec"
        return 0
    fi

    local bin_name
    bin_name="$(basename "${entrypoint}")"
    local bin_src="${PKGS_ROOT}/bin/${bin_name}"
    if [[ ! -f "${bin_src}" ]]; then
        echo "  SKIP ${name}: binary not found at bin/${bin_name}"
        return 0
    fi

    # Read version from spec metadata.version.
    local version
    version="$(sed -n '/^metadata:/,/^[^ ]/{ s/^[[:space:]]\{1,\}version:[[:space:]]*//p; }' "${spec}" | \
               head -1 | tr -d '"' | tr -d "'")"
    version="${version:-0.0.1}"

    # Assemble payload root in a per-package temp dir.
    local root="${WORK_DIR}/${name}"
    rm -rf "${root}"
    mkdir -p "${root}/bin" "${root}/specs"

    cp -L "${bin_src}" "${root}/bin/${bin_name}"
    cp "${spec}" "${root}/specs/${spec_file}"

    # Copy data/ from metadata dir (e.g. intent YAML nodes).
    if [[ -d "${meta}/data" ]]; then
        cp -a "${meta}/data" "${root}/data"
    fi

    # Pass --scripts-dir only when a scripts/ subdir exists.
    local scripts_flag=""
    if [[ -d "${meta}/scripts" ]]; then
        scripts_flag="--scripts-dir ${meta}/scripts"
    fi

    echo "  → pkg build ${name} (${version})..."
    # shellcheck disable=SC2086
    "${GLOBULAR}" pkg build \
        --spec "${root}/specs/${spec_file}" \
        --root "${root}" \
        ${scripts_flag} \
        --version "${version}" \
        --publisher "core@globular.io" \
        --platform "linux_amd64" \
        --out "${OUT_DIR}" \
        --skip-missing-config=true \
        --skip-missing-systemd=true 2>&1 | grep -v "^2026"
}

for spec in "${PKGS_ROOT}/metadata/"*/specs/*.yaml; do
    if build_one "${spec}"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Infrastructure packages: ${PASS} built, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
