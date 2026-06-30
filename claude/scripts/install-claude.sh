#!/bin/bash
# install-claude.sh — Fetch-at-install for the Anthropic Claude Code CLI.
#
# WHY THIS EXISTS
#   The real Claude CLI is a ~250MB proprietary native binary that is NOT shipped
#   in the Globular package payload (the package carries only the shared `noop`
#   sentinel for the verifier). This script fetches the pinned upstream version
#   from Anthropic's release CDN, verifies it against BOTH the per-version
#   manifest checksum AND a pinned sha256, and installs it to /usr/local/bin/claude
#   — the path ai_executor probes first.
#
# INVARIANTS HONORED
#   command.checksum_must_match_installed       — verify download == manifest == pinned sha
#   command.execution_within_supervisor_only    — run only as a node-agent install step
#   meta.half_done_must_not_look_done            — download to temp, verify, THEN atomic mv
#   meta.fallback_must_degrade_semantics         — fail closed; never leave a broken binary
#
# SELF-HEALING / FAIL-SOFT
#   - If the pinned version is already installed and runs, skip (no re-download).
#   - If the download or verification fails but a WORKING claude is already present,
#     keep it and exit 0 (a transient network blip must not break a good node).
#   - If nothing usable exists and we cannot verify a fresh binary, fail closed.
#
# BUMPING THE PINNED VERSION
#   Update CLAUDE_VERSION and CLAUDE_EXPECTED_SHA256 below (linux-x64), and the
#   `version:` field in package.json + specs/claude_cmd.yaml. The expected sha is
#   the `platforms["linux-x64"].checksum` value from:
#     https://downloads.claude.ai/claude-code-releases/<version>/manifest.json

set -euo pipefail

# ── Pinned upstream release ──────────────────────────────────────────────────
CLAUDE_VERSION="${CLAUDE_VERSION:-2.1.177}"
# Pinned sha256 for the linux-x64 artifact of CLAUDE_VERSION (defense-in-depth on
# top of the per-version manifest checksum). Leave empty to trust the manifest alone.
CLAUDE_EXPECTED_SHA256="${CLAUDE_EXPECTED_SHA256:-ff41753634b20c869ef6a32a20863521b33d4186ac0d6a49379ab48a48395ee7}"

DOWNLOAD_BASE_URL="${CLAUDE_DOWNLOAD_BASE_URL:-https://downloads.claude.ai/claude-code-releases}"
TARGET="${CLAUDE_TARGET:-/usr/local/bin/claude}"

log() { echo "[claude/install] $*"; }
die() { echo "[claude/install] ERROR: $*" >&2; exit 1; }

# ── 0) Already at the pinned version? ────────────────────────────────────────
if [[ -x "$TARGET" ]]; then
    current="$("$TARGET" --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
    if [[ "$current" == "$CLAUDE_VERSION" ]]; then
        log "claude $CLAUDE_VERSION already installed at $TARGET — nothing to do"
        exit 0
    fi
    log "found claude '${current:-unknown}' at $TARGET; target is $CLAUDE_VERSION"
fi

# Keep the current binary as the fail-soft fallback.
have_working_claude() { [[ -x "$TARGET" ]] && "$TARGET" --version >/dev/null 2>&1; }

# ── 1) Detect platform (mirrors the official installer) ──────────────────────
case "$(uname -s)" in
    Linux) os="linux" ;;
    *) die "unsupported OS $(uname -s); claude package targets Linux nodes" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "unsupported architecture $(uname -m)" ;;
esac
if [[ -f /lib/libc.musl-x86_64.so.1 ]] || [[ -f /lib/libc.musl-aarch64.so.1 ]] || ldd /bin/ls 2>&1 | grep -q musl; then
    platform="linux-${arch}-musl"
else
    platform="linux-${arch}"
fi
log "platform=$platform version=$CLAUDE_VERSION"

# ── 2) Fetch the per-version manifest and pull the authoritative checksum ─────
fetch() { curl -fsSL --retry 3 --retry-delay 2 "$@"; }

manifest_json="$(fetch "$DOWNLOAD_BASE_URL/$CLAUDE_VERSION/manifest.json" 2>/dev/null || true)"
if [[ -z "$manifest_json" ]]; then
    if have_working_claude; then
        log "WARN: could not fetch manifest (network?); keeping existing working claude"
        exit 0
    fi
    die "could not fetch manifest for $CLAUDE_VERSION and no working claude present"
fi

if command -v jq >/dev/null 2>&1; then
    manifest_sha="$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")"
else
    manifest_sha="$(echo "$manifest_json" | tr -d '\n' \
        | grep -oE "\"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"[a-f0-9]{64}\"" \
        | grep -oE '[a-f0-9]{64}' | head -1)"
fi
[[ "$manifest_sha" =~ ^[a-f0-9]{64}$ ]] || die "platform $platform not found in manifest for $CLAUDE_VERSION"

# Cross-check the manifest against our pinned sha (only meaningful for the pinned platform).
if [[ -n "$CLAUDE_EXPECTED_SHA256" && "$platform" == "linux-x64" && "$manifest_sha" != "$CLAUDE_EXPECTED_SHA256" ]]; then
    die "manifest checksum $manifest_sha != pinned $CLAUDE_EXPECTED_SHA256 (refusing — possible upstream tamper or stale pin)"
fi

# ── 3) Download to a temp file, verify, THEN atomic install ──────────────────
tmp="$(mktemp /tmp/claude.XXXXXX)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

if ! fetch -o "$tmp" "$DOWNLOAD_BASE_URL/$CLAUDE_VERSION/$platform/claude"; then
    if have_working_claude; then
        log "WARN: download failed; keeping existing working claude"
        exit 0
    fi
    die "download failed and no working claude present"
fi

actual_sha="$(sha256sum "$tmp" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$manifest_sha" ]]; then
    if have_working_claude; then
        log "WARN: checksum mismatch on download ($actual_sha); keeping existing working claude"
        exit 0
    fi
    die "checksum verification failed: got $actual_sha want $manifest_sha"
fi

# ── 4) Atomic install (root:root 0755) ───────────────────────────────────────
chmod 0755 "$tmp"
chown root:root "$tmp" 2>/dev/null || true
mkdir -p "$(dirname "$TARGET")"
mv -f "$tmp" "$TARGET"
trap - EXIT

# ── 5) Prove the installed binary runs and is the pinned version ─────────────
installed="$("$TARGET" --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
[[ "$installed" == "$CLAUDE_VERSION" ]] || die "installed claude reports '${installed:-unknown}', expected $CLAUDE_VERSION"

log "installed claude $CLAUDE_VERSION at $TARGET (sha256 $actual_sha verified)"
exit 0
