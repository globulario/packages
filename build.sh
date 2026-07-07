#!/usr/bin/env bash
# build.sh — Build the STATIC Globular packages into <out> (default: packages/dist).
#
# STATIC vs DYNAMIC:
#   - STATIC  (THIS script): every metadata/<name>/specs/*.yaml whose
#       metadata.kind is 'infrastructure' or 'command' — includes xds and gateway.
#       Binaries are third-party downloads, pre-staged Go bins (xds/gateway), or
#       none (OS-daemon / .deb / fetch-at-install wrappers with entrypoint: none).
#   - DYNAMIC (NOT this script): gRPC service packages (kind: service) are built
#       by services/scripts/regenerate-release-inputs.sh into services/generated.
#
# BINARIES (staged into bin/):
#   - vendored third-party  -> downloaded from upstream at the spec's version
#   - xds, gateway          -> expected PRE-STAGED in bin/ (built from ../Globular);
#                              skip+warn if missing (do NOT download)
#   - entrypoint: none      -> no binary (keepalived, scylladb, claude, codex, ...)
#
# registry.yaml is NOT used (deprecated). A package's identity/kind/version comes
# from its own metadata/<name>/specs/*.yaml (+ package.json).
#
# Usage:
#   bash build.sh --out <dir>            # download binaries + build static packages
#   bash build.sh --out <dir> --dry-run  # classify + report only (no downloads, no builds)
#
# GLOBULAR_BIN overrides the globular CLI path.

set -euo pipefail

PKGS_ROOT="$(cd "$(dirname "$0")" && pwd)"
GLOBULAR="${GLOBULAR_BIN:-globular}"
BIN_DIR="${PKGS_ROOT}/bin"
OUT_DIR="${PKGS_ROOT}/dist"
DRY_RUN=0
PLATFORM_VERSION=""   # applied to specs that declare metadata.platform_version: true
DEBS_DIR=""           # dir of pre-downloaded .debs for bundle_debs (scylladb); skips apt-get

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --platform-version) PLATFORM_VERSION="$2"; shift 2 ;;
        --debs-dir) DEBS_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

mkdir -p "${OUT_DIR}" "${BIN_DIR}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ── spec helpers (metadata is the source of truth; no registry.yaml) ──────────
# Read a metadata.<field> from a spec file.
spec_field() {  # <spec-file> <field>
    sed -n "/^metadata:/,/^[^ ]/{ s/^[[:space:]]\{1,\}$2:[[:space:]]*//p; }" "$1" 2>/dev/null \
        | head -1 | sed "s/[\"']//g"
}
spec_kind()    { spec_field "$1" kind; }
spec_version() { local v; v="$(spec_field "$1" version)"; echo "${v:-0.0.1}"; }
# Resolve entrypoint: metadata.entrypoint, else a top-level `entrypoint:`.
spec_entrypoint() {  # <spec-file>
    local e; e="$(spec_field "$1" entrypoint)"
    [[ -z "$e" ]] && e="$(grep -m1 '^entrypoint:' "$1" 2>/dev/null | sed 's/^entrypoint:[[:space:]]*//' | sed "s/[\"']//g")"
    echo "$e"
}
# Locate the spec file for a metadata package name.
spec_path_for() { ls "${PKGS_ROOT}/metadata/$1/specs/"*.yaml 2>/dev/null | head -1; }

# ── binary staging helpers ────────────────────────────────────────────────────
# Download a binary into bin/ if it's missing or the wrong version. In --dry-run
# it only reports what WOULD happen.
ensure_binary() {  # <bin-path> <version> <version-check-cmd> <download-cmd>
    local bin="$1" version="$2" check_cmd="$3" download_fn="$4"
    local current=""
    if [[ -f "${bin}" ]]; then
        current=$(eval "${check_cmd}" 2>&1 || echo "unknown")
        if [[ "${current}" == "${version}" ]]; then
            echo "    ✓ $(basename "${bin}") ${version} already present"; return 0
        fi
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "    ↧ WOULD download $(basename "${bin}") ${version} (have: ${current:-<absent>})"; return 0
    fi
    echo "    ↧ downloading $(basename "${bin}") ${version} (have: ${current:-<absent>})..."
    eval "${download_fn}"
    echo "    ✓ $(basename "${bin}") ${version}"
}
# Stage a locally-present binary (minio / scylla toolchain) after a version match.
# Version mismatch is a WARNING + skip (not a hard failure), so the run continues.
stage_local_binary() {  # <src> <dst> <expected-version> <version-check-cmd> <label>
    local src="$1" dst="$2" expected="$3" check_cmd="$4" label="$5"
    if [[ -z "${src}" || ! -x "${src}" ]]; then
        echo "    ⚠ ${label}: source binary not found (${src:-<empty>}) — provide it or set ${label^^}_BIN"; return 0
    fi
    local current; current=$(eval "${check_cmd}" 2>/dev/null | head -1 | tr -d '\r' || true)
    if [[ "${current}" != "${expected}" ]]; then
        echo "    ⚠ ${label}: version drift — spec '${expected}' vs binary '${current:-<empty>}' (${src}); fix the spec version or stage a matching binary"; return 0
    fi
    [[ "${DRY_RUN}" -eq 1 ]] && { echo "    ✓ ${label} ${expected} (would stage from ${src})"; return 0; }
    cp "${src}" "${dst}"; chmod +x "${dst}"
    echo "    ✓ ${label} ${expected} (staged from ${src})"
}

# ── STEP 1: download / stage third-party binaries (versions from specs) ────────
echo "→ Staging third-party binaries into bin/ (versions from spec metadata)"
V() { spec_version "$(spec_path_for "$1")"; }   # V <metadata-name>

ensure_binary "${BIN_DIR}/envoy" "$(V envoy)" \
    "${BIN_DIR}/envoy --version 2>&1 | grep -oP 'version: \K[0-9.]+'" \
    "curl -sL 'https://github.com/envoyproxy/envoy/releases/download/v$(V envoy)/envoy-$(V envoy)-linux-x86_64' -o '${BIN_DIR}/envoy' && chmod +x '${BIN_DIR}/envoy'"

ensure_binary "${BIN_DIR}/etcd" "$(V etcd)" \
    "${BIN_DIR}/etcd --version 2>&1 | grep -oP 'etcd Version: \K[0-9.]+'" \
    "cd /tmp && curl -sL 'https://github.com/etcd-io/etcd/releases/download/v$(V etcd)/etcd-v$(V etcd)-linux-amd64.tar.gz' -o etcd.tgz && tar xzf etcd.tgz && cp etcd-v$(V etcd)-linux-amd64/etcd etcd-v$(V etcd)-linux-amd64/etcdctl '${BIN_DIR}/' && chmod +x '${BIN_DIR}/etcd' '${BIN_DIR}/etcdctl' && rm -rf etcd-v$(V etcd)-linux-amd64 etcd.tgz && cd - >/dev/null"

ensure_binary "${BIN_DIR}/prometheus" "$(V prometheus)" \
    "${BIN_DIR}/prometheus --version 2>&1 | grep -oP 'version \K[0-9.]+'" \
    "cd /tmp && curl -sL 'https://github.com/prometheus/prometheus/releases/download/v$(V prometheus)/prometheus-$(V prometheus).linux-amd64.tar.gz' -o prom.tgz && tar xzf prom.tgz && cp prometheus-$(V prometheus).linux-amd64/prometheus prometheus-$(V prometheus).linux-amd64/promtool '${BIN_DIR}/' && chmod +x '${BIN_DIR}/prometheus' '${BIN_DIR}/promtool' && rm -rf prometheus-$(V prometheus).linux-amd64 prom.tgz && cd - >/dev/null"

ensure_binary "${BIN_DIR}/alertmanager" "$(V alertmanager)" \
    "${BIN_DIR}/alertmanager --version 2>&1 | grep -oP 'version \K[0-9.]+'" \
    "cd /tmp && curl -sL 'https://github.com/prometheus/alertmanager/releases/download/v$(V alertmanager)/alertmanager-$(V alertmanager).linux-amd64.tar.gz' -o am.tgz && tar xzf am.tgz && cp alertmanager-$(V alertmanager).linux-amd64/alertmanager alertmanager-$(V alertmanager).linux-amd64/amtool '${BIN_DIR}/' && chmod +x '${BIN_DIR}/alertmanager' '${BIN_DIR}/amtool' && rm -rf alertmanager-$(V alertmanager).linux-amd64 am.tgz && cd - >/dev/null"

ensure_binary "${BIN_DIR}/node_exporter" "$(V node-exporter)" \
    "${BIN_DIR}/node_exporter --version 2>&1 | grep -oP 'version \K[0-9.]+'" \
    "cd /tmp && curl -sL 'https://github.com/prometheus/node_exporter/releases/download/v$(V node-exporter)/node_exporter-$(V node-exporter).linux-amd64.tar.gz' -o ne.tgz && tar xzf ne.tgz && cp node_exporter-$(V node-exporter).linux-amd64/node_exporter '${BIN_DIR}/' && chmod +x '${BIN_DIR}/node_exporter' && rm -rf node_exporter-$(V node-exporter).linux-amd64 ne.tgz && cd - >/dev/null"

ensure_binary "${BIN_DIR}/sidekick" "$(V sidekick)" \
    "${BIN_DIR}/sidekick --version 2>&1 | grep -oP 'version: \K[0-9.]+'" \
    "curl -sL 'https://github.com/minio/sidekick/releases/latest/download/sidekick-linux-amd64' -o '${BIN_DIR}/sidekick' && chmod +x '${BIN_DIR}/sidekick'"

ensure_binary "${BIN_DIR}/restic" "$(V restic)" \
    "${BIN_DIR}/restic version 2>&1 | awk 'NR==1{print \$2}'" \
    "cd /tmp && curl -sL 'https://github.com/restic/restic/releases/download/v$(V restic)/restic_$(V restic)_linux_amd64.bz2' -o restic.bz2 && bunzip2 -f restic.bz2 && mv restic '${BIN_DIR}/restic' && chmod +x '${BIN_DIR}/restic' && cd - >/dev/null"

ensure_binary "${BIN_DIR}/rclone" "$(V rclone)" \
    "${BIN_DIR}/rclone version 2>&1 | awk 'NR==1{sub(/^v/,\"\",\$2); print \$2}'" \
    "cd /tmp && rm -rf rclone-v$(V rclone)-linux-amd64 rclone.zip && curl -sL 'https://downloads.rclone.org/v$(V rclone)/rclone-v$(V rclone)-linux-amd64.zip' -o rclone.zip && python3 -c \"import zipfile; z=zipfile.ZipFile('rclone.zip'); n=[x for x in z.namelist() if x.endswith('/rclone')][0]; z.extract(n,'.')\" && cp rclone-v$(V rclone)-linux-amd64/rclone '${BIN_DIR}/rclone' && chmod +x '${BIN_DIR}/rclone' && rm -rf rclone-v$(V rclone)-linux-amd64 rclone.zip && cd - >/dev/null"

ensure_binary "${BIN_DIR}/mc" "$(V mc)" \
    "${BIN_DIR}/mc --version 2>&1 | head -1 | grep -o 'RELEASE\\.[^ ]*'" \
    "curl -sL 'https://dl.min.io/client/mc/release/linux-amd64/mc' -o '${BIN_DIR}/mc' && chmod +x '${BIN_DIR}/mc'"

ensure_binary "${BIN_DIR}/ffmpeg" "$(V ffmpeg)" \
    "${BIN_DIR}/ffmpeg -version 2>&1 | head -1 | sed -n 's/^ffmpeg version \\([^ -]*\\).*/\\1/p'" \
    "cd /tmp && rm -rf ffmpeg-* ffmpeg.tar.xz && curl -sL 'https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz' -o ffmpeg.tar.xz && tar -xJf ffmpeg.tar.xz && cp \$(find ffmpeg-* -type f -name ffmpeg | head -1) '${BIN_DIR}/ffmpeg' && chmod +x '${BIN_DIR}/ffmpeg' && rm -rf ffmpeg-* ffmpeg.tar.xz && cd - >/dev/null"

# yt-dlp and sha256sum are taken from the local system (no pinned upstream url).
ensure_binary "${BIN_DIR}/yt-dlp" "$(V yt-dlp)" \
    "${BIN_DIR}/yt-dlp --version 2>&1 | head -1" \
    "cp /usr/bin/yt-dlp '${BIN_DIR}/yt-dlp' && chmod +x '${BIN_DIR}/yt-dlp'"
ensure_binary "${BIN_DIR}/sha256sum" "$(V sha256sum)" \
    "${BIN_DIR}/sha256sum --version 2>&1 | head -1 | awk '{print \$4}'" \
    "cp /usr/bin/sha256sum '${BIN_DIR}/sha256sum' && chmod +x '${BIN_DIR}/sha256sum'"

# Local-only toolchain (version governed by the spec, binary staged from system).
stage_local_binary "${MINIO_BIN:-/usr/bin/minio}" "${BIN_DIR}/minio" "$(V minio)" \
    "${MINIO_BIN:-/usr/bin/minio} --version 2>&1 | head -1 | grep -o 'RELEASE\\.[^ ]*'" "minio"
stage_local_binary "${SCYLLA_MANAGER_BIN:-$(command -v scylla-manager 2>/dev/null || true)}" "${BIN_DIR}/scylla_manager" "$(V scylla-manager)" \
    "${SCYLLA_MANAGER_BIN:-$(command -v scylla-manager 2>/dev/null || true)} --version 2>&1 | head -1" "scylla_manager"
stage_local_binary "${SCYLLA_MANAGER_AGENT_BIN:-$(command -v scylla-manager-agent 2>/dev/null || true)}" "${BIN_DIR}/scylla_manager_agent" "$(V scylla-manager-agent)" \
    "${SCYLLA_MANAGER_AGENT_BIN:-$(command -v scylla-manager-agent 2>/dev/null || true)} --version 2>&1 | head -1" "scylla_manager_agent"
stage_local_binary "${SCTOOL_BIN:-$(command -v sctool 2>/dev/null || true)}" "${BIN_DIR}/sctool" "$(V sctool)" \
    "${SCTOOL_BIN:-$(command -v sctool 2>/dev/null || true)} version 2>&1 | sed -n 's/^Client version: //p' | head -1" "sctool"

# xds / gateway are Go binaries built from ../Globular — NOT downloaded.
for gob in xds gateway; do
    if [[ -x "${BIN_DIR}/${gob}" ]]; then
        echo "    ✓ ${gob} pre-staged in bin/"
    else
        echo "    ⚠ ${gob}: not in bin/ — build it from ../Globular and stage bin/${gob} (package will be skipped)"
    fi
done

# ── STEP 1b: strip release binaries (release invariant: no debug/symbol sections) ─
# build-release.sh refuses to carry forward dist artifacts whose binaries still
# carry .debug_/.zdebug_/.symtab sections. Strip them here so packages/dist is
# release-clean. Go bins built with -s -w (xds/gateway) are already stripped.
if [[ "${DRY_RUN}" -eq 0 ]]; then
    echo "→ Stripping release binaries"
    for b in "${BIN_DIR}"/*; do
        [[ -f "$b" ]] || continue
        file -b "$b" 2>/dev/null | grep -q '^ELF' || continue
        if readelf -S "$b" 2>/dev/null | grep -Eq '\.(debug_|zdebug_|symtab)\b'; then
            strip --strip-unneeded "$b" 2>/dev/null || strip -s "$b" 2>/dev/null || true
            echo "    stripped $(basename "$b")"
        fi
    done
fi

# ── STEP 2: build every STATIC package (kind: infrastructure | command) ────────
echo "→ Building static packages (kind: infrastructure | command) → ${OUT_DIR}"
PASS=0; SKIP=0; FAIL=0
for spec in "${PKGS_ROOT}/metadata/"*/specs/*.yaml; do
    meta="$(cd "$(dirname "${spec}")/.." && pwd)"; name="$(basename "${meta}")"
    kind="$(spec_kind "${spec}")"
    # Only static packages here. Services (kind: service / unset) belong to
    # regenerate-release-inputs.sh -> services/generated.
    case "${kind}" in
        infrastructure|command) ;;
        *) continue ;;
    esac

    # Version: platform-release version for opted-in packages (xds/gateway/
    # globular-cli declare metadata.platform_version: true), else the spec's own.
    if [[ "$(spec_field "${spec}" platform_version)" == "true" && -n "${PLATFORM_VERSION}" ]]; then
        version="${PLATFORM_VERSION}"
    else
        version="$(spec_version "${spec}")"
    fi
    entrypoint="$(spec_entrypoint "${spec}")"

    # Classify the binary requirement (pkg build does the real resolution from the
    # full bin/ symlink; we only need the expected NAME to pre-check presence):
    #   none/noop      -> binary-less package (no bin payload)
    #   <empty>        -> auto-discovered Go binary (xds/gateway): expect bin/<name>
    #   explicit path  -> expect bin/<basename(entrypoint)>
    binreq=""; binsrc=""
    if [[ "${entrypoint}" == "none" || "${entrypoint}" == "noop" ]]; then
        binsrc="entrypoint: none — no binary"
    elif [[ -z "${entrypoint}" ]]; then
        binreq="${name}"; binsrc="binary: bin/${name} (auto-discovered)"
    else
        binreq="$(basename "${entrypoint}")"; binsrc="binary: bin/${binreq}"
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        # Report the full intended set (downloads precede a real run, so do NOT
        # skip here on a not-yet-downloaded binary).
        echo "  would build ${name} ${version} (${kind}, ${binsrc})"; PASS=$((PASS+1)); continue
    fi

    # Real run: the binary must be present after STEP 1 (download / pre-stage).
    # A genuinely-missing binary (e.g. xds/gateway not staged) is a clean skip.
    if [[ -n "${binreq}" && ! -f "${BIN_DIR}/${binreq}" ]]; then
        echo "  SKIP ${name} (${kind}): binary bin/${binreq} not available"; SKIP=$((SKIP+1)); continue
    fi

    # Assemble the package source: the whole metadata/<name>/ (specs, config,
    # systemd, scripts, data) + the FULL bin/ so pkg build resolves the
    # entrypoint (explicit or auto-discovered) and pulls the right binary.
    root="${WORK_DIR}/${name}"; rm -rf "${root}"; mkdir -p "${root}"
    cp -a "${meta}/." "${root}/"
    rm -rf "${root}/bin"; ln -s "${BIN_DIR}" "${root}/bin"
    local_scripts=""; [[ -d "${meta}/scripts" ]] && local_scripts="--scripts-dir ${meta}/scripts"
    debs_flag=""; [[ -n "${DEBS_DIR}" ]] && debs_flag="--debs-dir ${DEBS_DIR}"

    echo "  → pkg build ${name} ${version} (${kind})..."
    blog="${WORK_DIR}/${name}.buildlog"
    # shellcheck disable=SC2086
    if "${GLOBULAR}" pkg build \
            --spec "${spec}" --root "${root}" ${local_scripts} ${debs_flag} \
            --version "${version}" --publisher "core@globular.io" \
            --platform "linux_amd64" --out "${OUT_DIR}" \
            --skip-missing-config=true --skip-missing-systemd=true >"${blog}" 2>&1; then
        grep -E "^\[OK\]|manifest:" "${blog}" | head -2
        PASS=$((PASS+1))
    elif grep -qiE "apt-get download|bundle_debs|Can't find a source" "${blog}"; then
        # bundle_debs needs the scylla apt repo or --debs-dir; a missing-asset
        # skip, not a build error. Provide --debs-dir on the build host.
        echo "  SKIP ${name} (${kind}): bundle_debs .debs unavailable (scylla apt repo or --debs-dir)"; SKIP=$((SKIP+1))
    else
        echo "  ✗ FAIL ${name}"; grep -v "^2026" "${blog}" | tail -6; FAIL=$((FAIL+1))
    fi
done

echo ""
echo "Static packages: ${PASS} built/planned, ${SKIP} skipped (missing binary), ${FAIL} failed"
[[ "${FAIL}" -gt 0 ]] && exit 1 || true
