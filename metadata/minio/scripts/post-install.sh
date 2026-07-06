#!/usr/bin/env bash
# post-install.sh — MinIO post-install: ensure service is running + bucket provisioning.
# On Day 0 (installer): runs after health_checks, service is already up.
# On Day 1 (node-agent): runs inside infrastructure.install, before service.restart
#   in the plan — so we start the service ourselves if needed.
# Idempotent: safe to run multiple times.
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-127.0.0.1}"

echo "[minio/post-install] Starting MinIO post-install..."

MINIO_CERT_DIR="${STATE_DIR}/.minio/certs"
CRED_FILE="${STATE_DIR}/minio/credentials"
CONTRACT_FILE="${GLOBULAR_MINIO_CONTRACT_PATH:-${STATE_DIR}/objectstore/minio.json}"

# ── 1. Ensure MinIO is running ───────────────────────────────────────────
# On Day 1, infrastructure.install runs post-install.sh before the plan's
# service.restart step. Start MinIO now so bucket provisioning works.
UNIT="globular-minio.service"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${UNIT}" >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "${UNIT}"; then
        echo "[minio/post-install] Starting ${UNIT}..."
        systemctl daemon-reload 2>/dev/null || true
        systemctl start "${UNIT}" 2>/dev/null || true
        # Wait for MinIO to be ready (up to 15s)
        for i in $(seq 1 15); do
            if systemctl is-active --quiet "${UNIT}"; then
                echo "[minio/post-install] ✓ MinIO started (took ${i}s)"
                break
            fi
            sleep 1
        done
    else
        echo "[minio/post-install] ✓ MinIO already running"
    fi
fi

# ── 2. Bucket provisioning ───────────────────────────────────────────────
if ! command -v mc >/dev/null 2>&1; then
    echo "[minio/post-install] 'mc' not on PATH — skipping bucket provisioning"
    echo "[minio/post-install] Buckets will be created on first access or by ensure-minio-buckets.sh"
    exit 0
fi

SCHEME="http"
if [[ -f "${MINIO_CERT_DIR}/public.crt" ]]; then
    SCHEME="https"
fi

IFS=":" read -r ACCESS_KEY SECRET_KEY < "${CRED_FILE}" || true
if [[ -z "${ACCESS_KEY:-}" || -z "${SECRET_KEY:-}" ]]; then
    echo "[minio/post-install] Cannot read credentials — skipping bucket provisioning"
    exit 0
fi

ALIAS="globular-postinst"
ENDPOINT="${SCHEME}://${NODE_IP}:9000"

mc alias rm "${ALIAS}" >/dev/null 2>&1 || true
if ! mc alias set "${ALIAS}" "${ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" --api s3v4 --insecure >/dev/null 2>&1; then
    echo "[minio/post-install] Cannot configure mc alias — MinIO may not be ready yet"
    exit 0
fi

# Quick connectivity check with retry
CONNECTED=0
for i in $(seq 1 5); do
    if mc admin info "${ALIAS}/" --insecure >/dev/null 2>&1; then
        CONNECTED=1
        break
    fi
    sleep 2
done

if [[ $CONNECTED -eq 0 ]]; then
    echo "[minio/post-install] MinIO not reachable after retries — skipping bucket provisioning"
    mc alias rm "${ALIAS}" >/dev/null 2>&1 || true
    exit 0
fi

# Read bucket name from contract
BUCKET_NAME="globular"
if [[ -f "${CONTRACT_FILE}" ]] && command -v python3 >/dev/null 2>&1; then
    BUCKET_NAME=$(python3 -c "import json; print(json.load(open('${CONTRACT_FILE}'))['bucket'])" 2>/dev/null || echo "globular")
fi

if mc ls "${ALIAS}/${BUCKET_NAME}/" --insecure >/dev/null 2>&1; then
    echo "[minio/post-install] ✓ Bucket '${BUCKET_NAME}' already exists"
else
    echo "[minio/post-install] Creating bucket '${BUCKET_NAME}'..."
    mc mb "${ALIAS}/${BUCKET_NAME}" --insecure
    echo "[minio/post-install] ✓ Bucket '${BUCKET_NAME}' created"
fi

mc anonymous set download "${ALIAS}/${BUCKET_NAME}" --insecure >/dev/null 2>&1 || true
mc alias rm "${ALIAS}" >/dev/null 2>&1 || true

echo "[minio/post-install] ✓ MinIO post-install complete"
