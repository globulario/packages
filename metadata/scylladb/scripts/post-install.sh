#!/bin/bash
# post-install.sh — ScyllaDB post-install for Day-0 and Day-1.
#
# CRITICAL: ScyllaDB 2025.3+ uses Raft-based topology. The FIRST START
# bootstraps an irreversible Raft group. Config must be correct BEFORE
# the first start — there is no second chance.
#
# This script:
#   1. Stops ScyllaDB (must not be running)
#   2. Detects local IP and discovers seed nodes from config.json/etcd
#   3. Wipes data for clean Raft bootstrap
#   4. Writes a complete scylla.yaml (never trusts dpkg default)
#   5. Creates /etc/scylla.d/ and systemd overrides
#   6. Starts ScyllaDB with the final config
#   7. Validates readiness

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-}"

echo "[scylladb/post-install] Starting ScyllaDB post-install..."

# ── 0. Protect existing ScyllaDB data ────────────────────────────────────
# ScyllaDB's Raft identity lives in /var/lib/scylla/data/system/. If that
# directory exists, this node has ALREADY bootstrapped into a Raft group.
# Wiping it would destroy the node's identity and cause an unrecoverable
# raft quorum deadlock. In that case, only update config and restart —
# NEVER wipe data.
EXISTING_DATA=false
if [[ -d /var/lib/scylla/data/system ]]; then
    EXISTING_DATA=true
    echo "[scylladb/post-install] Existing ScyllaDB data found — will NOT wipe (Raft identity preserved)"
fi

# Also skip entirely if ScyllaDB is already running and serving CQL.
if systemctl is-active --quiet scylla-server.service 2>/dev/null; then
    SCYLLA_IP=$(grep -oP "listen_address:\s*'\K[^']+" /etc/scylla/scylla.yaml 2>/dev/null || echo "")
    if [[ -n "${SCYLLA_IP}" ]] && timeout 3 bash -c "echo >/dev/tcp/${SCYLLA_IP}/9042" 2>/dev/null; then
        echo "[scylladb/post-install] ScyllaDB is already running and serving CQL on ${SCYLLA_IP}:9042"
        echo "[scylladb/post-install] Skipping reinstall to protect Raft cluster state"
        exit 0
    fi
    echo "[scylladb/post-install] ScyllaDB is active but CQL not ready — will update config and restart"
fi

# ── 0b. Ensure ScyllaDB is STOPPED ──────────────────────────────────────
systemctl stop scylla-server.service 2>/dev/null || true
echo "[scylladb/post-install] ScyllaDB stopped"

# ── 1. Detect local IP ───────────────────────────────────────────────────
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

# ── 2. Discover seed nodes ───────────────────────────────────────────────
# Read the bootstrap host from etcd_endpoints (written by join script).
# The first non-local endpoint is the Day-0 seed node.
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

# ── 3. Copy TLS certificates ─────────────────────────────────────────────
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

# ── 4. Wipe data for clean Raft bootstrap (ONLY on first install) ────────
if [[ "${EXISTING_DATA}" == "true" ]]; then
    echo "[scylladb/post-install] SKIPPING data wipe — existing Raft identity in /var/lib/scylla/data/system/"
    echo "[scylladb/post-install] To force a clean bootstrap, manually run: rm -rf /var/lib/scylla/data"
else
    echo "[scylladb/post-install] Wiping data for clean Raft bootstrap (first install)..."
    rm -rf /var/lib/scylla/data /var/lib/scylla/commitlog /var/lib/scylla/hints \
           /var/lib/scylla/view_hints /var/lib/scylla/coredump
fi
mkdir -p /var/lib/scylla/data /var/lib/scylla/commitlog
chown -R scylla:scylla /var/lib/scylla 2>/dev/null || true

# Ensure /var/lib/scylla/conf → /etc/scylla symlink
SCYLLA_DATA_CONF="/var/lib/scylla/conf"
if [[ -L "${SCYLLA_DATA_CONF}" ]]; then
    :
elif [[ -d "${SCYLLA_DATA_CONF}" ]]; then
    ln -sf /etc/scylla/scylla.yaml "${SCYLLA_DATA_CONF}/scylla.yaml"
else
    ln -sfn /etc/scylla "${SCYLLA_DATA_CONF}"
fi
echo "[scylladb/post-install] Data directories clean"

# ── 5. Write scylla.yaml from scratch ───────────────────────────────────
# NEVER trust the dpkg default (has listen_address: localhost, seeds: 127.0.0.1).
# Always write a complete config with correct addresses and seeds.
#
# OWNERSHIP GUARD: if this node has already bootstrapped a Raft identity
# (EXISTING_DATA=true), skip the rewrite. The controller owns scylla.yaml
# on an active cluster — overwriting it from package defaults would revert
# cluster-aware seeds to a single-node seed and could break a 3-node cluster.
# Only write on first install (no existing Raft data directory).
SCYLLA_YAML="/etc/scylla/scylla.yaml"
mkdir -p /etc/scylla

if [[ "${EXISTING_DATA}" == "true" && -f "${SCYLLA_YAML}" ]]; then
    echo "[scylladb/post-install] SKIPPING scylla.yaml rewrite — existing Raft identity (controller owns live config)"
else
echo "[scylladb/post-install] Writing scylla.yaml (seeds: ${SEED_IP}, listen: ${NODE_IP})"
cat > "${SCYLLA_YAML}" <<EOF
# Generated by Globular post-install — do not edit manually.
# The controller may overwrite this with cluster-aware config.
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
EOF
fi  # end EXISTING_DATA guard

# ── 6. Environment / sysconfig ────────────────────────────────────────────
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

# Ensure /etc/scylla.d/ exists with required conf files.
# The dpkg unit references EnvironmentFile=/etc/scylla.d/*.conf WITHOUT the
# optional prefix (-), so the directory MUST exist or systemd fails with
# "Failed with result 'resources'".
mkdir -p /etc/scylla.d
[[ -f /etc/scylla.d/dev-mode.conf ]] || echo "DEV_MODE=--developer-mode=1" > /etc/scylla.d/dev-mode.conf
[[ -f /etc/scylla.d/memory.conf ]]   || echo "# memory.conf" > /etc/scylla.d/memory.conf
[[ -f /etc/scylla.d/io.conf ]]       || echo "# io.conf" > /etc/scylla.d/io.conf
[[ -f /etc/scylla.d/cpuset.conf ]]   || echo "# cpuset.conf" > /etc/scylla.d/cpuset.conf

# ── 7. Systemd overrides ─────────────────────────────────────────────────
# The dpkg unit references /etc/sysconfig/scylla-server (RHEL) which doesn't
# exist on Ubuntu. Override to use /etc/default/scylla-server.
SCYLLA_OVERRIDE_DIR="/etc/systemd/system/scylla-server.service.d"
mkdir -p "${SCYLLA_OVERRIDE_DIR}"

cat > "${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf" <<SYSEOF
[Service]
EnvironmentFile=
EnvironmentFile=-${SCYLLA_ENV_FILE}
EnvironmentFile=-/etc/scylla.d/*.conf
SYSEOF

if [[ ! -f "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" ]]; then
    cat > "${SCYLLA_OVERRIDE_DIR}/dependencies.conf" <<'DEPEOF'
[Unit]
After=network-online.target
Wants=network-online.target
DEPEOF
fi

systemctl daemon-reload
echo "[scylladb/post-install] Systemd overrides installed"

# ── 8. FIRST START — Raft bootstrap happens here ────────────────────────
echo "[scylladb/post-install] Starting ScyllaDB (Raft bootstrap with seeds: ${SEED_IP})..."
systemctl enable scylla-server.service 2>/dev/null || true
systemctl start scylla-server.service || true

# ── 9. Readiness validation (non-blocking) ────────────────────────────
# ScyllaDB Raft cluster join can take 3-10 minutes on real hardware.
# Don't block the installer — the workflow engine has a separate
# wait_scylladb_ready step that polls for port 9042.
echo "[scylladb/post-install] ScyllaDB started (Raft join in progress)"
echo "[scylladb/post-install] Port 9042 readiness will be checked by the workflow engine"
echo "[scylladb/post-install] ScyllaDB post-install complete (listen: ${NODE_IP}, seeds: ${SEED_IP})"
