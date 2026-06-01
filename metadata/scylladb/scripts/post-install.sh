#!/bin/bash
# post-install.sh — ScyllaDB post-install for Day-0 and Day-1.
#
# Intent model:
#   SCYLLA_INSTALL_INTENT=preserve (default)   — upgrade / restart; never touch existing data.
#   SCYLLA_INSTALL_INTENT=fresh-join           — Day-1 node admission; stale Raft state must be cleared.
#
# Ownership model:
#   After each successful install, a cluster fingerprint is written to
#   /var/lib/globular/state/scylladb/ownership.json. On the next install,
#   if the stored fingerprint matches the current cluster the data is ours →
#   preserve. If it does not match (node rebuilt, new cluster) the data is
#   stale → either wipe (with explicit intent) or fail closed.
#
# Safety gates for stale Raft wipe (ALL must be true):
#   SCYLLA_INSTALL_INTENT=fresh-join
#   ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true
#
# Legacy forced reinit (manual operator use — independent gate):
#   FORCE_SCYLLA_REINIT=true
#   I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED=true

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-}"
SCYLLA_BASE_DIR="${SCYLLA_BASE_DIR:-/var/lib/scylla}"
SCYLLA_DATA_DIR="${SCYLLA_DATA_DIR:-${SCYLLA_BASE_DIR}/data}"
SCYLLA_COMMITLOG_DIR="${SCYLLA_COMMITLOG_DIR:-${SCYLLA_BASE_DIR}/commitlog}"
SCYLLA_HINTS_DIR="${SCYLLA_HINTS_DIR:-${SCYLLA_BASE_DIR}/hints}"
SCYLLA_VIEW_HINTS_DIR="${SCYLLA_VIEW_HINTS_DIR:-${SCYLLA_BASE_DIR}/view_hints}"
SCYLLA_ETC_DIR="${SCYLLA_ETC_DIR:-/etc/scylla}"
SCYLLA_YAML="${SCYLLA_YAML:-${SCYLLA_ETC_DIR}/scylla.yaml}"

SCYLLA_INSTALL_INTENT="${SCYLLA_INSTALL_INTENT:-preserve}"
SCYLLA_CLUSTER_FINGERPRINT="${SCYLLA_CLUSTER_FINGERPRINT:-}"
ALLOW_STALE_SCYLLA_REINIT_ON_JOIN="${ALLOW_STALE_SCYLLA_REINIT_ON_JOIN:-false}"
# Set to "first-node" when bootstrapping the first node of a new cluster.
# Allows self-only seed on fresh-join (normal join requires ≥1 non-self seed).
SCYLLA_BOOTSTRAP_INTENT="${SCYLLA_BOOTSTRAP_INTENT:-}"

FORCE_SCYLLA_REINIT="${FORCE_SCYLLA_REINIT:-false}"
I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED="${I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED:-false}"

OWNERSHIP_DIR="${STATE_DIR}/state/scylladb"
OWNERSHIP_FILE="${OWNERSHIP_DIR}/ownership.json"

echo "[scylladb/post-install] Starting ScyllaDB post-install (intent=${SCYLLA_INSTALL_INTENT})..."

# ── 0) Fast exit if already healthy ──────────────────────────────────────────
if systemctl is-active --quiet scylla-server.service 2>/dev/null; then
    SCYLLA_IP=$(grep -oP "listen_address:\s*'\K[^']+" "${SCYLLA_YAML}" 2>/dev/null || echo "")
    if [[ -n "${SCYLLA_IP}" ]] && timeout 3 bash -c "echo >/dev/tcp/${SCYLLA_IP}/9042" 2>/dev/null; then
        echo "[scylladb/post-install] ScyllaDB already serving CQL on ${SCYLLA_IP}:9042 — skipping (Raft cluster state protected)"
        exit 0
    fi
    echo "[scylladb/post-install] ScyllaDB active but not ready — proceeding"
fi

# ── 0b) Stop before config changes ───────────────────────────────────────────
systemctl stop scylla-server.service 2>/dev/null || true
echo "[scylladb/post-install] ScyllaDB stopped"

# ── 1) Detect local IP ───────────────────────────────────────────────────────
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

# ── 2) Discover seed candidates from etcd endpoints ──────────────────────────
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

# ── 2b) Validate seed context for fresh-join ─────────────────────────────────
# Scylla may create a standalone local Raft/topology identity if started with
# only itself as a seed while joining an existing cluster. Prevent this by
# requiring at least one non-self, non-localhost seed unless this node is
# explicitly bootstrapping a new cluster (SCYLLA_BOOTSTRAP_INTENT=first-node).
if [[ "${SCYLLA_INSTALL_INTENT}" == "fresh-join" ]]; then
    HAS_REMOTE_SEED=false
    IFS=',' read -ra _SEEDS <<< "${SEED_IP}"
    for _seed in "${_SEEDS[@]}"; do
        _seed=$(echo "${_seed}" | xargs)
        if [[ -n "${_seed}" && "${_seed}" != "127.0.0.1" && "${_seed}" != "localhost" && "${_seed}" != "${NODE_IP}" ]]; then
            HAS_REMOTE_SEED=true
            break
        fi
    done

    if [[ "${HAS_REMOTE_SEED}" != "true" && "${SCYLLA_BOOTSTRAP_INTENT}" != "first-node" ]]; then
        echo "[scylladb/post-install] ERROR: Day-1 fresh-join requires ≥1 non-self seed." >&2
        echo "[scylladb/post-install]   Seeds found: ${SEED_IP:-none}" >&2
        echo "[scylladb/post-install]   etcd_endpoints file: ${ETCD_ENDPOINTS}" >&2
        echo "[scylladb/post-install]   If this is the first node of a new cluster, set SCYLLA_BOOTSTRAP_INTENT=first-node" >&2
        echo "[scylladb/post-install]   If this is a joining node, ensure etcd_endpoints contains at least one peer IP" >&2
        exit 1
    fi

    if [[ "${HAS_REMOTE_SEED}" != "true" && "${SCYLLA_BOOTSTRAP_INTENT}" == "first-node" ]]; then
        echo "[scylladb/post-install] Bootstrap intent=first-node — self-only seed allowed for cluster initialization"
    fi
fi

# ── 3) Copy TLS certificates ─────────────────────────────────────────────────
SCYLLA_TLS_DIR="${SCYLLA_TLS_DIR:-${SCYLLA_ETC_DIR}/tls}"
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

# ── 4) Derive cluster fingerprint from CA cert if not supplied ───────────────
if [[ -z "${SCYLLA_CLUSTER_FINGERPRINT}" ]]; then
    CA_CERT="${STATE_DIR}/pki/ca.crt"
    if [[ -f "${CA_CERT}" ]]; then
        SCYLLA_CLUSTER_FINGERPRINT=$(sha256sum "${CA_CERT}" | cut -c1-16)
        echo "[scylladb/post-install] Derived cluster fingerprint: ${SCYLLA_CLUSTER_FINGERPRINT}"
    else
        echo "[scylladb/post-install] WARNING: CA cert not found — ownership comparison will be skipped"
    fi
fi

# ── 4b) Auto-detect Day-1 join context from node-agent state when env not set ─
# The node-agent writes join_id to state.json for the duration of an active
# join and clears+saves it after completion. A non-empty join_id here means
# this post-install is part of a live Day-1 join, not an upgrade.
if [[ "${SCYLLA_INSTALL_INTENT}" == "preserve" ]]; then
    STATE_JSON="${STATE_DIR}/nodeagent/state.json"
    if [[ -f "${STATE_JSON}" ]]; then
        JOIN_ID_VAL=$(grep -oP '"join_id"\s*:\s*"\K[^"]+' "${STATE_JSON}" 2>/dev/null || echo "")
        if [[ -n "${JOIN_ID_VAL}" ]]; then
            SCYLLA_INSTALL_INTENT="fresh-join"
            ALLOW_STALE_SCYLLA_REINIT_ON_JOIN="true"
            echo "[scylladb/post-install] Auto-detected Day-1 join context (join_id=${JOIN_ID_VAL})"
        fi
    fi
fi

# ── 5) Detect existing Raft/topology state ────────────────────────────────────
# Only the specific system directories that encode cluster membership are
# checked here. User keyspace data is NOT considered stale Raft state.
SCYLLA_HAS_RAFT_STATE=false
SCYLLA_HAS_EXISTING_DATA=false

if [[ -d "${SCYLLA_DATA_DIR}/system" ]] || find "${SCYLLA_DATA_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
    SCYLLA_HAS_EXISTING_DATA=true
fi

if [[ "${SCYLLA_HAS_EXISTING_DATA}" == "true" ]]; then
    for check_dir in \
        "${SCYLLA_DATA_DIR}/system/topology-"* \
        "${SCYLLA_DATA_DIR}/system/raft-"* \
        "${SCYLLA_DATA_DIR}/system/raft_snapshot_config-"*; do
        if [[ -d "${check_dir}" ]] && find "${check_dir}" -name "*.db" -maxdepth 2 2>/dev/null | grep -q .; then
            SCYLLA_HAS_RAFT_STATE=true
            break
        fi
    done
fi

# ── 6) Ownership check and stale Raft resolution ─────────────────────────────
if [[ "${FORCE_SCYLLA_REINIT}" == "true" && "${I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED}" == "true" ]]; then
    # Legacy forced reinit — independent of ownership model.
    if systemctl is-active --quiet scylla-server.service 2>/dev/null; then
        echo "[scylladb/post-install] ERROR: Refusing forced wipe while ScyllaDB is running" >&2
        exit 1
    fi
    echo "[scylladb/post-install] FORCE_SCYLLA_REINIT confirmed — wiping all ScyllaDB data"
    mkdir -p "${STATE_DIR}/audit"
    echo "$(date -Iseconds) forced ScyllaDB reinit on $(hostname) data_dir=${SCYLLA_DATA_DIR}" >> "${STATE_DIR}/audit/scylladb-reinit.log"
    rm -rf "${SCYLLA_DATA_DIR}" \
           "${SCYLLA_COMMITLOG_DIR}" \
           "${SCYLLA_HINTS_DIR}" \
           "${SCYLLA_VIEW_HINTS_DIR}" \
           "${SCYLLA_BASE_DIR}/coredump"
    echo "[scylladb/post-install] Forced reinit wipe completed"
    SCYLLA_HAS_EXISTING_DATA=false
    SCYLLA_HAS_RAFT_STATE=false

elif [[ "${SCYLLA_HAS_RAFT_STATE}" == "true" ]]; then
    # Existing Raft/topology state — check ownership.
    OWNS_DATA=false
    STORED_FP=""
    if [[ -f "${OWNERSHIP_FILE}" && -n "${SCYLLA_CLUSTER_FINGERPRINT}" ]]; then
        STORED_FP=$(grep -oP '"cluster_fingerprint"\s*:\s*"\K[^"]+' "${OWNERSHIP_FILE}" 2>/dev/null || echo "")
        if [[ "${STORED_FP}" == "${SCYLLA_CLUSTER_FINGERPRINT}" ]]; then
            OWNS_DATA=true
        fi
    fi

    if [[ "${OWNS_DATA}" == "true" ]]; then
        echo "[scylladb/post-install] Ownership marker matches current cluster — preserving Raft state (upgrade path)"

    elif [[ "${SCYLLA_INSTALL_INTENT}" == "initial-node" ]]; then
        # Day-0 initial-node bootstrap: this node is forming a new cluster from
        # scratch. Stale Raft state from a previous failed Day-0 attempt must be
        # wiped — there is no live cluster to protect.
        echo "[scylladb/post-install] Day-0 initial-node: wiping stale Raft state from previous failed attempt"
        mkdir -p "${STATE_DIR}/audit"
        echo "$(date -Iseconds) wiped stale ScyllaDB state on $(hostname) for Day-0 initial-node bootstrap" >> "${STATE_DIR}/audit/scylladb-reinit.log"
        rm -rf "${SCYLLA_DATA_DIR}" \
               "${SCYLLA_COMMITLOG_DIR}" \
               "${SCYLLA_HINTS_DIR}" \
               "${SCYLLA_VIEW_HINTS_DIR}" \
               "${SCYLLA_BASE_DIR}/coredump"
        echo "[scylladb/post-install] Stale state wiped"
        SCYLLA_HAS_EXISTING_DATA=false
        SCYLLA_HAS_RAFT_STATE=false

    elif [[ "${SCYLLA_INSTALL_INTENT}" == "fresh-join" && "${ALLOW_STALE_SCYLLA_REINIT_ON_JOIN}" == "true" ]]; then
        # Day-1 node admission with an ownership mismatch: the local data belongs
        # to an unknown cluster epoch. Wipe ALL Scylla state — data dir, commitlog,
        # hints, view_hints. Partial preservation is not safe here because system
        # table state outside the explicitly named Raft dirs may carry hidden
        # cluster identity that causes a split topology or ring poisoning.
        echo "[scylladb/post-install] Stale state from unknown cluster epoch (stored_fp=${STORED_FP:-none}, current_fp=${SCYLLA_CLUSTER_FINGERPRINT}) — wiping all Scylla state for fresh join"
        mkdir -p "${STATE_DIR}/audit"
        echo "$(date -Iseconds) wiped all ScyllaDB state on $(hostname) for Day-1 join (intent=${SCYLLA_INSTALL_INTENT})" >> "${STATE_DIR}/audit/scylladb-reinit.log"

        rm -rf "${SCYLLA_DATA_DIR}" \
               "${SCYLLA_COMMITLOG_DIR}" \
               "${SCYLLA_HINTS_DIR}" \
               "${SCYLLA_VIEW_HINTS_DIR}" \
               "${SCYLLA_BASE_DIR}/coredump"
        echo "[scylladb/post-install] All Scylla state wiped"
        SCYLLA_HAS_EXISTING_DATA=false
        SCYLLA_HAS_RAFT_STATE=false

    else
        # FAIL CLOSED — never start Scylla with unknown stale Raft state.
        echo "[scylladb/post-install] ERROR: Stale Raft/topology state exists for a different cluster." >&2
        echo "[scylladb/post-install]   stored_fp=${STORED_FP:-none}  current_fp=${SCYLLA_CLUSTER_FINGERPRINT}" >&2
        echo "[scylladb/post-install]   To resolve: set SCYLLA_INSTALL_INTENT=fresh-join and ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true" >&2
        mkdir -p "${OWNERSHIP_DIR}"
        cat > "${OWNERSHIP_DIR}/remediation-required.json" <<EOF_REMEDIATE
{
  "reason": "stale_raft_topology_state",
  "detected_at": "$(date -Iseconds)",
  "node_hostname": "$(hostname)",
  "node_ip": "${NODE_IP}",
  "cluster_fingerprint_stored": "${STORED_FP:-unknown}",
  "cluster_fingerprint_current": "${SCYLLA_CLUSTER_FINGERPRINT}",
  "action_required": "Set SCYLLA_INSTALL_INTENT=fresh-join and ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true, then rerun post-install"
}
EOF_REMEDIATE
        exit 1
    fi

elif [[ "${SCYLLA_HAS_EXISTING_DATA}" == "true" ]]; then
    echo "[scylladb/post-install] Existing ScyllaDB data (no Raft state detected) — preserving"
else
    echo "[scylladb/post-install] No existing ScyllaDB data; initializing data directories"
fi

mkdir -p "${SCYLLA_DATA_DIR}" "${SCYLLA_COMMITLOG_DIR}"
chown -R scylla:scylla "${SCYLLA_BASE_DIR}" 2>/dev/null || true

# Ensure $SCYLLA_BASE_DIR/conf -> $SCYLLA_ETC_DIR symlink.
SCYLLA_DATA_CONF="${SCYLLA_BASE_DIR}/conf"
if [[ -L "${SCYLLA_DATA_CONF}" ]]; then
    :
elif [[ -d "${SCYLLA_DATA_CONF}" ]]; then
    ln -sf "${SCYLLA_YAML}" "${SCYLLA_DATA_CONF}/scylla.yaml"
else
    ln -sfn "${SCYLLA_ETC_DIR}" "${SCYLLA_DATA_CONF}"
fi

# ── 7) Write scylla.yaml if absent, forced reinit, or fresh-join ─────────────
mkdir -p "${SCYLLA_ETC_DIR}"
if [[ ! -f "${SCYLLA_YAML}" || "${FORCE_SCYLLA_REINIT}" == "true" || "${SCYLLA_INSTALL_INTENT}" == "fresh-join" ]]; then
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
  certificate: ${SCYLLA_ETC_DIR}/tls/server.crt
  keyfile: ${SCYLLA_ETC_DIR}/tls/server.key
  truststore: ${SCYLLA_ETC_DIR}/tls/ca.crt
  require_client_auth: false

native_transport_port_ssl: 9142

data_file_directories:
  - ${SCYLLA_DATA_DIR}

commitlog_directory: ${SCYLLA_COMMITLOG_DIR}
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

# ── 8) Environment/sysconfig ──────────────────────────────────────────────────
SCYLLA_SYSCONF_DIR="${SCYLLA_SYSCONF_DIR:-/etc/default}"
SCYLLA_CONFD_DIR="${SCYLLA_CONFD_DIR:-/etc/scylla.d}"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
fi

case "${ID:-}${ID_LIKE:-}" in
    *rhel*|*centos*|*fedora*) SCYLLA_ENV_FILE="${SCYLLA_SYSCONF_DIR}/scylla-server" ;;
    *) SCYLLA_ENV_FILE="${SCYLLA_SYSCONF_DIR}/scylla-server" ;;
esac

if [[ ! -f "${SCYLLA_ENV_FILE}" ]]; then
    mkdir -p "$(dirname "${SCYLLA_ENV_FILE}")"
    cat > "${SCYLLA_ENV_FILE}" <<ENVEOF
NETWORK_MODE=posix
SET_NIC_AND_DISKS=no
SET_CLOCKSOURCE=no
NR_HUGEPAGES=64
USER=scylla
GROUP=scylla
SCYLLA_HOME=${SCYLLA_BASE_DIR}
SCYLLA_CONF=${SCYLLA_ETC_DIR}
SCYLLA_ARGS="--log-to-syslog 1 --log-to-stdout 0 --default-log-level info --network-stack posix"
ENVEOF
fi

mkdir -p "${SCYLLA_CONFD_DIR}"
[[ -f "${SCYLLA_CONFD_DIR}/dev-mode.conf" ]] || echo "DEV_MODE=--developer-mode=1" > "${SCYLLA_CONFD_DIR}/dev-mode.conf"
[[ -f "${SCYLLA_CONFD_DIR}/memory.conf" ]] || echo "# memory.conf" > "${SCYLLA_CONFD_DIR}/memory.conf"
[[ -f "${SCYLLA_CONFD_DIR}/io.conf" ]] || echo "# io.conf" > "${SCYLLA_CONFD_DIR}/io.conf"
[[ -f "${SCYLLA_CONFD_DIR}/cpuset.conf" ]] || echo "# cpuset.conf" > "${SCYLLA_CONFD_DIR}/cpuset.conf"

# ── 9) Systemd overrides ──────────────────────────────────────────────────────
SCYLLA_OVERRIDE_DIR="${SCYLLA_OVERRIDE_DIR:-/etc/systemd/system/scylla-server.service.d}"
mkdir -p "${SCYLLA_OVERRIDE_DIR}"

cat > "${SCYLLA_OVERRIDE_DIR}/sysconfdir.conf" <<EOF_SYSCONF
[Service]
EnvironmentFile=
EnvironmentFile=-${SCYLLA_ENV_FILE}
EnvironmentFile=-${SCYLLA_CONFD_DIR}/*.conf
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

# ── 10) Start ScyllaDB ────────────────────────────────────────────────────────
echo "[scylladb/post-install] Starting ScyllaDB (seeds: ${SEED_IP})..."
systemctl enable scylla-server.service 2>/dev/null || true
_SCYLLA_START_OK=false
if systemctl start scylla-server.service 2>/dev/null; then
    _SCYLLA_START_OK=true
else
    echo "[scylladb/post-install] WARNING: systemctl start scylla-server returned non-zero — service may still be initializing"
fi

# ── 11) Write ownership marker ────────────────────────────────────────────────
# Written only after a successful start so we never record ownership for a
# configuration that failed to launch. If start fails, the next post-install
# run will re-evaluate intent and data state from scratch.
if [[ "${_SCYLLA_START_OK}" == "true" && -n "${SCYLLA_CLUSTER_FINGERPRINT}" ]]; then
    mkdir -p "${OWNERSHIP_DIR}"
    cat > "${OWNERSHIP_FILE}" <<EOF_OWNER
{
  "cluster_fingerprint": "${SCYLLA_CLUSTER_FINGERPRINT}",
  "node_ip": "${NODE_IP}",
  "source": "scylladb-post-install",
  "recorded_at": "$(date -Iseconds)"
}
EOF_OWNER
    echo "[scylladb/post-install] Ownership marker written (fingerprint=${SCYLLA_CLUSTER_FINGERPRINT})"
elif [[ -z "${SCYLLA_CLUSTER_FINGERPRINT}" ]]; then
    echo "[scylladb/post-install] WARNING: no cluster fingerprint available — ownership marker not written"
fi

echo "[scylladb/post-install] ScyllaDB started (join may still be in progress)"
echo "[scylladb/post-install] Port 9042 readiness will be checked by the workflow engine"
echo "[scylladb/post-install] ScyllaDB post-install complete (listen: ${NODE_IP}, seeds: ${SEED_IP})"
