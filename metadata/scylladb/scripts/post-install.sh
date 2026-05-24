#!/bin/bash
# post-install.sh — ScyllaDB post-install for Day-0 and Day-1.
#
# Non-destructive invariant:
#   - Existing Scylla data is protected state.
#   - Post-install must never wipe existing data automatically.
#   - Data wipe requires explicit dual confirmation flags.

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-}"
SCYLLA_DATA_DIR="/var/lib/scylla/data"
SCYLLA_COMMITLOG_DIR="/var/lib/scylla/commitlog"
SCYLLA_YAML="/etc/scylla/scylla.yaml"

FORCE_SCYLLA_REINIT="${FORCE_SCYLLA_REINIT:-false}"
I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED="${I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED:-false}"

echo "[scylladb/post-install] Starting ScyllaDB post-install..."

# 0) Fast exit if already healthy.
if systemctl is-active --quiet scylla-server.service 2>/dev/null; then
    SCYLLA_IP=$(grep -oP "listen_address:\s*'\K[^']+" "${SCYLLA_YAML}" 2>/dev/null || echo "")
    if [[ -n "${SCYLLA_IP}" ]] && timeout 3 bash -c "echo >/dev/tcp/${SCYLLA_IP}/9042" 2>/dev/null; then
        echo "[scylladb/post-install] ScyllaDB already serving CQL on ${SCYLLA_IP}:9042"
        echo "[scylladb/post-install] Skipping reinstall to protect Raft cluster state"
        exit 0
    fi
    echo "[scylladb/post-install] ScyllaDB active but not ready — proceeding non-destructively"
fi

# 0b) Stop before config changes.
systemctl stop scylla-server.service 2>/dev/null || true
echo "[scylladb/post-install] ScyllaDB stopped"

# 1) Detect local IP.
if [[ -z "${NODE_IP}" ]]; then
    NODE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
fi
if [[ -z "${NODE_IP}" ]]; then
    NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [[ -z "${NODE_IP}" ]]; then
    echo "[scylladb/post-install] ERROR: Cannot detect local IP" >&2
    exit 1
fi
echo "[scylladb/post-install] Node IP: ${NODE_IP}"

# 2) Discover seed candidates from etcd endpoints.
SEED_IP="${NODE_IP}"
ETCD_ENDPOINTS="${STATE_DIR}/config/etcd_endpoints"
if [[ -f "${ETCD_ENDPOINTS}" ]]; then
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's|https://||;s|http://||;s|:.*||' | xargs)
        if [[ -n "$line" && "$line" != "127.0.0.1" && "$line" != "localhost" && "$line" != "${NODE_IP}" ]]; then
            SEED_IP="${line},${NODE_IP}"
            break
        fi
    done < "${ETCD_ENDPOINTS}"
fi
echo "[scylladb/post-install] Seeds: ${SEED_IP}"

# 2b) Seed mismatch is advisory only (non-destructive).
if [[ -f "${SCYLLA_YAML}" ]]; then
    CURRENT_SEEDS=$(grep -A2 'seeds:' "${SCYLLA_YAML}" | grep -oP "seeds:\s*'\K[^']+" || echo "")
    if [[ -n "${CURRENT_SEEDS}" && -n "${SEED_IP}" && "${CURRENT_SEEDS}" != *"${SEED_IP%%,*}"* ]]; then
        echo "[scylladb/post-install] WARNING: Seeds mismatch detected (have: ${CURRENT_SEEDS}, need: ${SEED_IP})"
        echo "[scylladb/post-install] Data will be preserved. Controller remediation required if node cannot join."
        mkdir -p "${STATE_DIR}/state/scylladb"
        cat > "${STATE_DIR}/state/scylladb/remediation-required.json" <<EOF_JSON
{
  "reason": "seed_mismatch",
  "existing_seeds": "${CURRENT_SEEDS}",
  "expected_seed": "${SEED_IP}",
  "timestamp": "$(date -Iseconds)"
}
EOF_JSON
    fi
fi

# 3) Copy TLS certificates.
SCYLLA_TLS_DIR="/etc/scylla/tls"
PKI_CERT_DIR="${STATE_DIR}/pki/issued/services"
PKI_DIR="${STATE_DIR}/pki"

mkdir -p "${SCYLLA_TLS_DIR}"
if [[ -f "${PKI_CERT_DIR}/service.crt" ]]; then
    cp "${PKI_CERT_DIR}/service.crt" "${SCYLLA_TLS_DIR}/server.crt"
    cp "${PKI_CERT_DIR}/service.key" "${SCYLLA_TLS_DIR}/server.key"
    cp "${PKI_DIR}/ca.pem" "${SCYLLA_TLS_DIR}/ca.crt"
    chown -R scylla:scylla "${SCYLLA_TLS_DIR}" 2>/dev/null || true
    chmod 755 "${SCYLLA_TLS_DIR}"
    chmod 644 "${SCYLLA_TLS_DIR}/server.crt" "${SCYLLA_TLS_DIR}/ca.crt"
    chmod 400 "${SCYLLA_TLS_DIR}/server.key"
    echo "[scylladb/post-install] TLS certificates copied"
else
    echo "[scylladb/post-install] WARNING: PKI certs not found — TLS setup skipped"
fi

# 4) Non-destructive data handling + explicit forced reinit gate.
SCYLLA_HAS_EXISTING_DATA=false
if [[ -d "${SCYLLA_DATA_DIR}/system" ]] || find "${SCYLLA_DATA_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
    SCYLLA_HAS_EXISTING_DATA=true
fi

if [[ "${SCYLLA_HAS_EXISTING_DATA}" == "true" ]]; then
    echo "[scylladb/post-install] Existing ScyllaDB data detected under ${SCYLLA_DATA_DIR}"
    echo "[scylladb/post-install] Refusing to wipe data during post-install"

    if [[ "${FORCE_SCYLLA_REINIT}" == "true" && "${I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED}" == "true" ]]; then
        echo "[scylladb/post-install] FORCE_SCYLLA_REINIT confirmed. This will destroy local ScyllaDB data."
        if systemctl is-active --quiet scylla-server.service 2>/dev/null; then
            echo "[scylladb/post-install] ERROR: Refusing forced wipe while ScyllaDB is running" >&2
            exit 1
        fi

        mkdir -p "${STATE_DIR}/audit"
        echo "$(date -Iseconds) forced ScyllaDB reinit on $(hostname) data_dir=${SCYLLA_DATA_DIR}" >> "${STATE_DIR}/audit/scylladb-reinit.log"

        rm -rf /var/lib/scylla/data \
               /var/lib/scylla/commitlog \
               /var/lib/scylla/hints \
               /var/lib/scylla/view_hints \
               /var/lib/scylla/coredump
        echo "[scylladb/post-install] Forced reinit wipe completed"
    else
        echo "[scylladb/post-install] Keeping existing data and continuing with non-destructive config update"
    fi
else
    echo "[scylladb/post-install] No existing ScyllaDB data detected; initializing data directories"
fi

mkdir -p "${SCYLLA_DATA_DIR}" "${SCYLLA_COMMITLOG_DIR}"
chown -R scylla:scylla /var/lib/scylla 2>/dev/null || true

# Ensure /var/lib/scylla/conf -> /etc/scylla symlink.
SCYLLA_DATA_CONF="/var/lib/scylla/conf"
if [[ -L "${SCYLLA_DATA_CONF}" ]]; then
    :
elif [[ -d "${SCYLLA_DATA_CONF}" ]]; then
    ln -sf /etc/scylla/scylla.yaml "${SCYLLA_DATA_CONF}/scylla.yaml"
else
    ln -sfn /etc/scylla "${SCYLLA_DATA_CONF}"
fi

# 5) Write safe default scylla.yaml if absent or when forced reinit was requested.
mkdir -p /etc/scylla
if [[ ! -f "${SCYLLA_YAML}" || "${FORCE_SCYLLA_REINIT}" == "true" ]]; then
    echo "[scylladb/post-install] Writing scylla.yaml (seeds: ${SEED_IP}, listen: ${NODE_IP})"
    cat > "${SCYLLA_YAML}" <<EOF_SCYLLA
# Generated by Globular post-install — do not edit manually.
cluster_name: 'globular.internal'

seed_provider:
  - class_name: org.apache.cassandra.locator.SimpleSeedProvider
    parameters:
      - seeds: '${SEED_IP}'

listen_address: '${NODE_IP}'
rpc_address: '${NODE_IP}'
broadcast_address: '${NODE_IP}'
broadcast_rpc_address: '${NODE_IP}'

native_transport_port: 9042
endpoint_snitch: SimpleSnitch
developer_mode: true

client_encryption_options:
  enabled: true
  certificate: /etc/scylla/tls/server.crt
  keyfile: /etc/scylla/tls/server.key
  truststore: /etc/scylla/tls/ca.crt
  require_client_auth: false

native_transport_port_ssl: 9142

data_file_directories:
  - /var/lib/scylla/data

commitlog_directory: /var/lib/scylla/commitlog
commitlog_sync: batch
commitlog_sync_batch_window_in_ms: 2
commitlog_sync_period_in_ms: 10000
auto_adjust_flush_quota: true

compaction_throughput_mb_per_sec: 0
compaction_large_partition_warning_threshold_mb: 100

api_port: 10000
api_address: '${NODE_IP}'
EOF_SCYLLA
else
    echo "[scylladb/post-install] Existing scylla.yaml preserved"
fi

# 6) Environment/sysconfig.
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
fi

case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) SCYLLA_ENV_FILE="/etc/default/scylla-server" ;;
    *rhel*|*centos*|*fedora*) SCYLLA_ENV_FILE="/etc/sysconfig/scylla-server" ;;
    *) SCYLLA_ENV_FILE="/etc/default/scylla-server" ;;
esac

if [[ ! -f "${SCYLLA_ENV_FILE}" ]]; then
    mkdir -p "$(dirname "${SCYLLA_ENV_FILE}")"
    cat > "${SCYLLA_ENV_FILE}" <<'ENVEOF'
NETWORK_MODE=posix
SET_NIC_AND_DISKS=no
SET_CLOCKSOURCE=no
NR_HUGEPAGES=64
USER=scylla
GROUP=scylla
SCYLLA_HOME=/var/lib/scylla
SCYLLA_CONF=/etc/scylla
SCYLLA_ARGS="--log-to-syslog 1 --log-to-stdout 0 --default-log-level info --network-stack posix"
ENVEOF
fi

mkdir -p /etc/scylla.d
[[ -f /etc/scylla.d/dev-mode.conf ]] || echo "DEV_MODE=--developer-mode=1" > /etc/scylla.d/dev-mode.conf
[[ -f /etc/scylla.d/memory.conf ]] || echo "# memory.conf" > /etc/scylla.d/memory.conf
[[ -f /etc/scylla.d/io.conf ]] || echo "# io.conf" > /etc/scylla.d/io.conf
[[ -f /etc/scylla.d/cpuset.conf ]] || echo "# cpuset.conf" > /etc/scylla.d/cpuset.conf

# 7) Systemd overrides.
SCYLLA_OVERRIDE_DIR="/etc/systemd/system/scylla-server.service.d"
mkdir -p "${SCYLLA_OVERRIDE_DIR}"

cat > "${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf" <<EOF_SYSCONF
[Service]
EnvironmentFile=
EnvironmentFile=-${SCYLLA_ENV_FILE}
EnvironmentFile=-/etc/scylla.d/*.conf
EOF_SYSCONF

if [[ ! -f "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" ]]; then
    cat > "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" <<'EOF_DEP'
[Unit]
After=network-online.target
Wants=network-online.target
EOF_DEP
fi

systemctl daemon-reload
echo "[scylladb/post-install] Systemd overrides installed"

# 8) Start ScyllaDB.
echo "[scylladb/post-install] Starting ScyllaDB (non-destructive path, seeds: ${SEED_IP})..."
systemctl enable scylla-server.service 2>/dev/null || true
systemctl start scylla-server.service || true

# 9) Readiness is checked by workflow.
echo "[scylladb/post-install] ScyllaDB started (join may still be in progress)"
echo "[scylladb/post-install] Port 9042 readiness will be checked by the workflow engine"
echo "[scylladb/post-install] ScyllaDB post-install complete (listen: ${NODE_IP}, seeds: ${SEED_IP})"
