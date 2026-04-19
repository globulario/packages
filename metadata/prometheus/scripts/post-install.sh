#!/usr/bin/env bash
# post-install.sh — Prometheus post-install: generate MinIO bearer token for metrics scraping.
# Derived from provision-minio-token.sh. Idempotent: safe to run multiple times.
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
CRED_FILE="${STATE_DIR}/minio/credentials"
TOKEN_FILE="${STATE_DIR}/prometheus/minio_token"

echo "[prometheus/post-install] Starting Prometheus post-install..."

# ── 0. Install alert rules ────────────────────────────────────────────────
# Source of truth: config/prometheus/rules/globular_alerts.yml (from package payload)
# Runtime location: ${STATE_DIR}/prometheus/rules/ (where Prometheus reads them)
RULES_SRC="${PACKAGE_ROOT:-}/config/prometheus/rules"
RULES_DST="${STATE_DIR}/prometheus/rules"
if [[ -d "${RULES_SRC}" ]]; then
    mkdir -p "${RULES_DST}"
    cp -a "${RULES_SRC}/." "${RULES_DST}/"
    chown -R globular:globular "${RULES_DST}" 2>/dev/null || true
    chmod 0750 "${RULES_DST}"
    echo "[prometheus/post-install] ✓ Alert rules installed to ${RULES_DST}"
else
    echo "[prometheus/post-install] No rules directory in package payload — skipping"
fi

# ── 1. Generate MinIO bearer token ───────────────────────────────────────
if ! command -v mc >/dev/null 2>&1; then
    echo "[prometheus/post-install] 'mc' not found — skipping MinIO token generation"
    echo "[prometheus/post-install] Run provision-minio-token.sh after mc is installed"
    exit 0
fi

if [[ ! -f "${CRED_FILE}" ]]; then
    echo "[prometheus/post-install] MinIO credentials not found at ${CRED_FILE} — skipping token"
    exit 0
fi

IFS=":" read -r ACCESS_KEY SECRET_KEY < "${CRED_FILE}" || true
if [[ -z "${ACCESS_KEY:-}" || -z "${SECRET_KEY:-}" ]]; then
    echo "[prometheus/post-install] Empty credentials — skipping token"
    exit 0
fi

# Determine scheme
SCHEME="http"
if [[ -f "${STATE_DIR}/.minio/certs/public.crt" ]]; then
    SCHEME="https"
fi
MINIO_HOST="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
ENDPOINT="${SCHEME}://${MINIO_HOST}:9000"

ALIAS="globular-prom"
mc alias rm "${ALIAS}" >/dev/null 2>&1 || true
if ! mc alias set "${ALIAS}" "${ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" --api s3v4 --insecure >/dev/null 2>&1; then
    echo "[prometheus/post-install] Cannot connect to MinIO — skipping token generation"
    exit 0
fi

TOKEN=$(mc admin prometheus generate "${ALIAS}" --insecure 2>/dev/null \
    | grep -oP 'bearer_token:\s*\K\S+' || true)

if [[ -z "${TOKEN}" ]]; then
    TOKEN=$(mc admin prometheus generate "${ALIAS}" --insecure 2>&1 \
        | grep -oP 'bearer_token_file.*token["\s:]+\K[A-Za-z0-9_-]+' || true)
fi

mc alias rm "${ALIAS}" >/dev/null 2>&1 || true

if [[ -z "${TOKEN}" ]]; then
    echo "[prometheus/post-install] Could not extract bearer token — skipping"
    echo "[prometheus/post-install] Run provision-minio-token.sh manually"
    exit 0
fi

mkdir -p "$(dirname "${TOKEN_FILE}")"
printf '%s' "${TOKEN}" > "${TOKEN_FILE}"
chown globular:globular "${TOKEN_FILE}" 2>/dev/null || true
chmod 0640 "${TOKEN_FILE}"
echo "[prometheus/post-install] ✓ MinIO token written to ${TOKEN_FILE}"

# ── 2. Reload Prometheus if running ──────────────────────────────────────
if systemctl is-active --quiet globular-prometheus.service 2>/dev/null; then
    curl -sS -X POST http://127.0.0.1:9090/-/reload 2>/dev/null || true
    echo "[prometheus/post-install] ✓ Prometheus reloaded"
fi

echo "[prometheus/post-install] ✓ Prometheus post-install complete"
