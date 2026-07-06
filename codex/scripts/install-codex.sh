#!/bin/bash
# install-codex.sh — Fetch-at-install for the OpenAI Codex CLI.
#
# WHY THIS EXISTS
#   The real Codex CLI vendor tree is not shipped in the Globular package
#   payload. This script fetches the pinned npm platform tarball, verifies its
#   sha512, extracts the complete vendor tree (binary + adjacent resources), and
#   installs it under /usr/local/lib/codex with /usr/local/bin/codex symlinked
#   to the real binary.
#
# INVARIANTS HONORED
#   command.checksum_must_match_installed
#   command.execution_within_supervisor_only
#   meta.half_done_must_not_look_done
#   meta.fallback_must_degrade_semantics
#
# SELF-HEALING / FAIL-SOFT
#   - If the pinned version is already installed and runs, skip.
#   - If download or verification fails but a working codex already exists, keep
#     it and exit 0.
#   - If nothing usable exists and we cannot verify a fresh install, fail closed.

set -euo pipefail

CODEX_VERSION="${CODEX_VERSION:-0.142.3}"
CODEX_X64_SHA512="${CODEX_X64_SHA512:-110e6cbe697babc9559bdbf208663247cdce82417df79c52ae52eae48c20213d6df931a198b6a3a349878e64136a1216f204a618cb116534c8fa9e458d13eb54}"
CODEX_ARM64_SHA512="${CODEX_ARM64_SHA512:-781e20b669f03094add3b60fd57975f54d33a87e1a0dc64d0b7c3d764cccc5b9f4349ae40261fcb81f0a2d29957b3ec2ff6f103fc13d69a372f8479941f6b154}"
DOWNLOAD_BASE_URL="${CODEX_DOWNLOAD_BASE_URL:-https://registry.npmjs.org/@openai/codex/-}"
INSTALL_ROOT="${CODEX_INSTALL_ROOT:-/usr/local/lib/codex}"
TARGET="${CODEX_TARGET:-/usr/local/bin/codex}"

log() { echo "[codex/install] $*"; }
die() { echo "[codex/install] ERROR: $*" >&2; exit 1; }

have_working_codex() { [[ -x "$TARGET" ]] && "$TARGET" --version >/dev/null 2>&1; }

if [[ -x "$TARGET" ]]; then
    current="$("$TARGET" --version 2>/dev/null | sed -n 's/^codex-cli[[:space:]]\+//p' | head -1 || true)"
    if [[ "$current" == "$CODEX_VERSION" ]]; then
        log "codex $CODEX_VERSION already installed at $TARGET — nothing to do"
        exit 0
    fi
    log "found codex '${current:-unknown}' at $TARGET; target is $CODEX_VERSION"
fi

case "$(uname -s)" in
    Linux) ;;
    *) die "unsupported OS $(uname -s); codex package targets Linux nodes" ;;
esac
case "$(uname -m)" in
    x86_64|amd64)
        suffix="linux-x64"
        vendor_dir="x86_64-unknown-linux-musl"
        expected_sha512="$CODEX_X64_SHA512"
        ;;
    arm64|aarch64)
        suffix="linux-arm64"
        vendor_dir="aarch64-unknown-linux-musl"
        expected_sha512="$CODEX_ARM64_SHA512"
        ;;
    *)
        die "unsupported architecture $(uname -m)"
        ;;
esac

archive="codex-${CODEX_VERSION}-${suffix}.tgz"
url="${DOWNLOAD_BASE_URL}/${archive}"
target_dir="${INSTALL_ROOT}/${vendor_dir}"

fetch() { curl -fsSL --retry 3 --retry-delay 2 "$@"; }

tmp="$(mktemp /tmp/codex.XXXXXX.tgz)"
stage="$(mktemp -d /tmp/codex-stage.XXXXXX)"
cleanup() {
    rm -f "$tmp"
    rm -rf "$stage"
}
trap cleanup EXIT

if ! fetch -o "$tmp" "$url"; then
    if have_working_codex; then
        log "WARN: download failed; keeping existing working codex"
        exit 0
    fi
    die "download failed and no working codex present"
fi

actual_sha512="$(sha512sum "$tmp" | cut -d' ' -f1)"
if [[ "$actual_sha512" != "$expected_sha512" ]]; then
    if have_working_codex; then
        log "WARN: checksum mismatch on download ($actual_sha512); keeping existing working codex"
        exit 0
    fi
    die "sha512 verification failed: got $actual_sha512 want $expected_sha512"
fi

if ! tar -xzf "$tmp" -C "$stage" "package/vendor/${vendor_dir}"; then
    if have_working_codex; then
        log "WARN: extract failed; keeping existing working codex"
        exit 0
    fi
    die "failed to extract vendor tree package/vendor/${vendor_dir}"
fi

extracted="${stage}/package/vendor/${vendor_dir}"
[[ -x "${extracted}/bin/codex" ]] || die "extracted payload missing bin/codex"

mkdir -p "$INSTALL_ROOT"
rm -rf "$target_dir"
mv "$extracted" "$target_dir"
ln -sfn "${target_dir}/bin/codex" "$TARGET"

installed="$("$TARGET" --version 2>/dev/null | sed -n 's/^codex-cli[[:space:]]\+//p' | head -1 || true)"
[[ "$installed" == "$CODEX_VERSION" ]] || die "installed codex reports '${installed:-unknown}', expected $CODEX_VERSION"

log "installed codex $CODEX_VERSION at $TARGET (sha512 $actual_sha512 verified)"
exit 0
