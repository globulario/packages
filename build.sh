#!/usr/bin/env bash
# build.sh — Build all infrastructure packages from specs/ + metadata/ + bin/.
#
# Usage (from packages/ dir):
#   bash build.sh --out <output-dir>
#
# For each spec in specs/, assembles a payload root:
#   <tmpdir>/bin/<binary>     — copied from bin/ (pre-built by build-all-packages.sh)
#   <tmpdir>/specs/           — from specs/<name>_service.yaml
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
# package.json, every spec (top-level specs/ AND metadata/*/specs/), and the systemd
# unit before a single package is built. Guards against the recurring mcp "mcp" vs
# "mcp_server" drift (fixed by hand 5+ times). Fail loud, never ship.
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

    # Derive metadata dir name: strip _service.yaml / _cmd.yaml, underscores→hyphens.
    local name
    name="$(echo "${spec_file}" | sed 's/_service\.yaml$//' | sed 's/_cmd\.yaml$//' | tr '_' '-')"

    local meta="${PKGS_ROOT}/metadata/${name}"
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

for spec in "${PKGS_ROOT}/specs/"*.yaml; do
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
