#!/usr/bin/env bash
# pre-start.sh — MinIO pre-start: TLS cert symlinks, credentials, contract.
# Must run BEFORE MinIO starts so it reads TLS certs and boots in HTTPS mode.
# Idempotent: safe to run multiple times.
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-127.0.0.1}"
DOMAIN="${GLOBULAR_DOMAIN:-${DOMAIN:-localhost}}"

echo "[minio/pre-start] Preparing MinIO environment..."

# ── 1. TLS cert symlinks ──────────────────────────────────────────────────
# MinIO expects certs at ~/.minio/certs/{public.crt,private.key}.
# Globular stores service certs in the PKI directory.
MINIO_CERT_DIR="${STATE_DIR}/.minio/certs"
PKI_CERT="${STATE_DIR}/pki/issued/services/service.crt"
PKI_KEY="${STATE_DIR}/pki/issued/services/service.key"

if [[ -f "${PKI_CERT}" && -f "${PKI_KEY}" ]]; then
    mkdir -p "${MINIO_CERT_DIR}"
    ln -sf "${PKI_CERT}" "${MINIO_CERT_DIR}/public.crt"
    ln -sf "${PKI_KEY}" "${MINIO_CERT_DIR}/private.key"

    # Also copy CA for client verification
    if [[ -f "${STATE_DIR}/pki/ca.pem" ]]; then
        mkdir -p "${MINIO_CERT_DIR}/CAs"
        cp -f "${STATE_DIR}/pki/ca.pem" "${MINIO_CERT_DIR}/CAs/ca.crt"
    fi

    chown -R globular:globular "${MINIO_CERT_DIR}" 2>/dev/null || true
    echo "[minio/pre-start] ✓ TLS cert symlinks created"
else
    echo "[minio/pre-start] ⚠ PKI certs not found at ${PKI_CERT} — TLS symlinks skipped"
    echo "[minio/pre-start]   MinIO will start in HTTP mode"
fi

# ── 2. Credentials file ──────────────────────────────────────────────────
CRED_FILE="${STATE_DIR}/minio/credentials"
if [[ ! -f "${CRED_FILE}" ]]; then
    echo "[minio/pre-start] Creating default credentials at ${CRED_FILE}..."
    mkdir -p "$(dirname "${CRED_FILE}")"
    echo "globular:globularadmin" > "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"
    chown globular:globular "${CRED_FILE}" 2>/dev/null || true
    echo "[minio/pre-start] ✓ Default credentials created"
else
    echo "[minio/pre-start] ✓ Credentials file already exists"
fi

# ── 3. Contract JSON ─────────────────────────────────────────────────────
CONTRACT_DIR="${STATE_DIR}/objectstore"
CONTRACT_FILE="${GLOBULAR_MINIO_CONTRACT_PATH:-${CONTRACT_DIR}/minio.json}"

if [[ ! -f "${CONTRACT_FILE}" ]]; then
    mkdir -p "${CONTRACT_DIR}"

    if ! IFS=":" read -r MINIO_ACCESS_KEY MINIO_SECRET_KEY < "${CRED_FILE}"; then
        echo "[minio/pre-start] ERROR: Cannot read credentials from ${CRED_FILE}" >&2
        exit 1
    fi

    cat > "${CONTRACT_FILE}" <<EOJSON
{
  "type": "minio",
  "endpoint": "${NODE_IP}:9000",
  "bucket": "globular",
  "prefix": "${DOMAIN}",
  "secure": true,
  "caBundlePath": "${STATE_DIR}/pki/ca.pem",
  "auth": {
    "mode": "file",
    "credFile": "${CRED_FILE}"
  }
}
EOJSON
    chown globular:globular "${CONTRACT_FILE}" 2>/dev/null || true
    chmod 644 "${CONTRACT_FILE}" 2>/dev/null || true
    echo "[minio/pre-start] ✓ Contract written to ${CONTRACT_FILE}"
else
    echo "[minio/pre-start] ✓ Contract file already exists"
fi

echo "[minio/pre-start] ✓ MinIO environment ready"
