#!/bin/bash
# post-install_test.sh — unit tests for post-install.sh ownership/Raft logic.
#
# Tests run without systemd, ScyllaDB, or real PKI. They exercise only the
# decision logic (ownership check, stale-Raft detection, intent gates, forced
# reinit) by injecting controlled state into a temp directory.
#
# Run: bash post-install_test.sh
# Exit: 0 = all passed, non-zero = number of failures

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_INSTALL="${SCRIPT_DIR}/post-install.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

TMP_ROOT=""

setup() {
    TMP_ROOT=$(mktemp -d)
    # Minimal directory structure the script expects.
    mkdir -p \
        "${TMP_ROOT}/state/scylladb" \
        "${TMP_ROOT}/pki/issued/services" \
        "${TMP_ROOT}/nodeagent" \
        "${TMP_ROOT}/config" \
        "${TMP_ROOT}/audit"

    # Fake CA cert (content doesn't matter — only sha256sum matters).
    echo "FAKE_CA_CERT_DATA_$(uname -n)" > "${TMP_ROOT}/pki/ca.crt"

    # Fake scylla data dirs.
    mkdir -p \
        "${TMP_ROOT}/scylla/data" \
        "${TMP_ROOT}/scylla/commitlog" \
        "${TMP_ROOT}/scylla/hints" \
        "${TMP_ROOT}/scylla/view_hints"
}

teardown() {
    [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]] && rm -rf "${TMP_ROOT}"
}

# run_script EXTRA_ENV_PAIRS...
# Runs post-install.sh in a subshell with systemd, file I/O, and IP detection
# all overridden for testing. Returns exit status.
run_script() {
    local extra_env=("$@")

    # Stub out all side-effect commands.
    local stub_bin="${TMP_ROOT}/stub_bin"
    mkdir -p "${stub_bin}"

    # systemctl stub — never actually starts/stops anything.
    cat > "${stub_bin}/systemctl" <<'SH'
#!/bin/bash
case "${1}" in
    "is-active") exit 1 ;;   # report inactive
    *)            exit 0 ;;
esac
SH
    chmod +x "${stub_bin}/systemctl"

    # ip stub — return test IP.
    cat > "${stub_bin}/ip" <<'SH'
#!/bin/bash
echo "src 10.1.2.3"
SH
    chmod +x "${stub_bin}/ip"

    # Redirect all scylla dirs to tmp so tests run without root.
    local scylla_base="${TMP_ROOT}/scylla"
    local scylla_data="${scylla_base}/data"
    local scylla_clog="${scylla_base}/commitlog"
    local scylla_hints="${scylla_base}/hints"
    local scylla_vhints="${scylla_base}/view_hints"
    local scylla_etc="${TMP_ROOT}/etc/scylla"
    local scylla_yaml="${scylla_etc}/scylla.yaml"
    local scylla_confd="${TMP_ROOT}/etc/scylla.d"
    local scylla_sysconf="${TMP_ROOT}/etc/default"
    local sysctl_dir="${TMP_ROOT}/systemd/system/scylla-server.service.d"
    mkdir -p "${sysctl_dir}" "${scylla_confd}" "${scylla_sysconf}" "${scylla_etc}"

    env \
        PATH="${stub_bin}:${PATH}" \
        STATE_DIR="${TMP_ROOT}" \
        NODE_IP="10.1.2.3" \
        SCYLLA_BASE_DIR="${scylla_base}" \
        SCYLLA_DATA_DIR="${scylla_data}" \
        SCYLLA_COMMITLOG_DIR="${scylla_clog}" \
        SCYLLA_HINTS_DIR="${scylla_hints}" \
        SCYLLA_VIEW_HINTS_DIR="${scylla_vhints}" \
        SCYLLA_ETC_DIR="${scylla_etc}" \
        SCYLLA_YAML="${scylla_yaml}" \
        SCYLLA_CONFD_DIR="${scylla_confd}" \
        SCYLLA_SYSCONF_DIR="${scylla_sysconf}" \
        SCYLLA_OVERRIDE_DIR="${sysctl_dir}" \
        "${extra_env[@]}" \
        bash "${POST_INSTALL}" 2>&1
}

assert_exit() {
    local name="$1" expected="$2" actual="$3" output="$4"
    if [[ "${actual}" -eq "${expected}" ]]; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (expected exit=${expected}, got exit=${actual})"
        echo "        output: $(echo "${output}" | head -5)"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [[ -f "${path}" ]]; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (file missing: ${path})"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_absent() {
    local name="$1" path="$2"
    if [[ ! -e "${path}" ]]; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (file should not exist: ${path})"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_absent() {
    local name="$1" path="$2"
    if [[ ! -d "${path}" ]]; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (directory should not exist: ${path})"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_exists() {
    local name="$1" path="$2"
    if [[ -d "${path}" ]]; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (directory missing: ${path})"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local name="$1" path="$2" needle="$3"
    if grep -q "${needle}" "${path}" 2>/dev/null; then
        echo "  PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${name} (expected '${needle}' in ${path})"
        FAIL=$((FAIL + 1))
    fi
}

# ── Inject a remote peer into etcd_endpoints ────────────────────────────────
# Simulates a node that has a cluster peer (non-first-node Day-1 join).
inject_remote_seed() {
    local peer_ip="${1:-10.0.0.1}"
    echo "https://${peer_ip}:2379" > "${TMP_ROOT}/config/etcd_endpoints"
}

# ── Compute current cluster fingerprint (same logic as the script) ────────────
cluster_fp() {
    sha256sum "${TMP_ROOT}/pki/ca.crt" | cut -c1-16
}

# ── Write an ownership marker with the given fingerprint ─────────────────────
write_ownership() {
    local fp="$1"
    cat > "${TMP_ROOT}/state/scylladb/ownership.json" <<JSON
{
  "cluster_fingerprint": "${fp}",
  "node_ip": "10.1.2.3",
  "recorded_at": "2026-01-01T00:00:00+00:00"
}
JSON
}

# ── Create fake Raft SSTable files ────────────────────────────────────────────
create_raft_state() {
    local data_dir="${TMP_ROOT}/scylla/data"
    mkdir -p "${data_dir}/system/topology-abc123" \
              "${data_dir}/system/raft-def456" \
              "${data_dir}/system/raft_snapshot_config-ghi789"
    echo "fake_sstable" > "${data_dir}/system/topology-abc123/me-1-big-Data.db"
    echo "fake_sstable" > "${data_dir}/system/raft-def456/me-1-big-Data.db"
    echo "fake_sstable" > "${data_dir}/system/raft_snapshot_config-ghi789/me-1-big-Data.db"
    # Also create a user keyspace to verify it is NOT wiped.
    mkdir -p "${data_dir}/my_keyspace/my_table-aabbcc"
    echo "user_data" > "${data_dir}/my_keyspace/my_table-aabbcc/data.db"
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: Clean node — no prior data — starts successfully and writes ownership.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 1: Clean node starts and writes ownership marker (first-node bootstrap)"
setup
# First-node bootstrap: fresh-join intent, no remote seeds → needs SCYLLA_BOOTSTRAP_INTENT=first-node.
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=fresh-join" \
    "ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true" \
    "SCYLLA_BOOTSTRAP_INTENT=first-node") || rc=$?
assert_exit "clean-node exits 0" 0 "${rc}" "${output}"
assert_file_exists "ownership.json written" "${TMP_ROOT}/state/scylladb/ownership.json"
assert_file_contains "ownership.json has fingerprint" \
    "${TMP_ROOT}/state/scylladb/ownership.json" "cluster_fingerprint"
assert_file_contains "ownership.json has source field" \
    "${TMP_ROOT}/state/scylladb/ownership.json" "scylladb-post-install"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: Valid ownership marker — existing Raft state — data is PRESERVED.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: Valid ownership marker — Raft data preserved (upgrade path)"
setup
create_raft_state
write_ownership "$(cluster_fp)"
rc=0; output=$(run_script "SCYLLA_INSTALL_INTENT=preserve") || rc=$?
assert_exit "preserve exits 0" 0 "${rc}" "${output}"
# Raft dirs must still exist.
assert_dir_exists "topology dir preserved" \
    "${TMP_ROOT}/scylla/data/system/topology-abc123"
assert_dir_exists "raft dir preserved" \
    "${TMP_ROOT}/scylla/data/system/raft-def456"
# User keyspace must still exist.
assert_dir_exists "user keyspace preserved" \
    "${TMP_ROOT}/scylla/data/my_keyspace"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: Stale Raft state, NO fresh-join intent → FAIL CLOSED.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: Stale Raft state without fresh-join intent — fail closed"
setup
create_raft_state
write_ownership "stale0000fingerprint"   # different cluster's fingerprint
rc=0; output=$(run_script "SCYLLA_INSTALL_INTENT=preserve") || rc=$?
assert_exit "fail-closed exits non-zero" 1 "${rc}" "${output}"
assert_file_exists "remediation-required.json written" \
    "${TMP_ROOT}/state/scylladb/remediation-required.json"
assert_file_contains "remediation reason recorded" \
    "${TMP_ROOT}/state/scylladb/remediation-required.json" "stale_raft_topology_state"
# Raft dirs must NOT have been wiped.
assert_dir_exists "raft dir not touched on fail-closed" \
    "${TMP_ROOT}/scylla/data/system/raft-def456"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: Stale Raft state WITH fresh-join intent → system Raft dirs wiped,
#         user keyspace preserved.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: Stale state (ownership mismatch) with fresh-join intent — ALL Scylla state wiped"
setup
create_raft_state
write_ownership "stale0000fingerprint"
inject_remote_seed "10.0.0.1"   # simulate joining an existing cluster
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=fresh-join" \
    "ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true") || rc=$?
assert_exit "fresh-join exits 0" 0 "${rc}" "${output}"
# data/ and commitlog/ are recreated empty by post-install — assert their
# prior contents (user keyspace, Raft dirs) are gone.
assert_dir_absent "user keyspace wiped" \
    "${TMP_ROOT}/scylla/data/my_keyspace"
assert_dir_absent "topology dir wiped" \
    "${TMP_ROOT}/scylla/data/system/topology-abc123"
assert_dir_absent "raft dir wiped" \
    "${TMP_ROOT}/scylla/data/system/raft-def456"
# New ownership marker must match current cluster.
assert_file_contains "ownership updated to current fp" \
    "${TMP_ROOT}/state/scylladb/ownership.json" "$(cluster_fp)"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: Auto-detect Day-1 join via state.json join_id — triggers fresh-join.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: Auto-detect Day-1 join from state.json join_id"
setup
create_raft_state
write_ownership "stale0000fingerprint"
inject_remote_seed "10.0.0.1"
# Inject a non-empty join_id (simulates an active Day-1 join).
cat > "${TMP_ROOT}/nodeagent/state.json" <<JSON
{"join_id": "abc-123-def-456", "node_id": "test-node-01"}
JSON
# Run with default preserve intent — auto-detection should promote to fresh-join.
rc=0; output=$(run_script "SCYLLA_INSTALL_INTENT=preserve") || rc=$?
assert_exit "auto-detect exits 0" 0 "${rc}" "${output}"
# Raft dirs wiped because intent was promoted.
assert_dir_absent "topology dir wiped via auto-detect" \
    "${TMP_ROOT}/scylla/data/system/topology-abc123"
assert_dir_absent "raft dir wiped via auto-detect" \
    "${TMP_ROOT}/scylla/data/system/raft-def456"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 6: FORCE_SCYLLA_REINIT requires BOTH flags — only one set → ignored.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: Forced reinit requires both flags — one flag alone does nothing"
setup
create_raft_state
write_ownership "stale0000fingerprint"
# Only set FORCE, not I_UNDERSTAND — falls through to fresh-join path (intent=preserve → fail-closed).
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=preserve" \
    "FORCE_SCYLLA_REINIT=true") || rc=$?
assert_exit "single-flag forced reinit exits non-zero" 1 "${rc}" "${output}"
assert_dir_exists "raft data NOT wiped with single flag" \
    "${TMP_ROOT}/scylla/data/system/raft-def456"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 7: FORCE_SCYLLA_REINIT with both flags → wipes ALL scylla data dirs.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: Forced reinit with both flags — all scylla data wiped"
setup
create_raft_state
write_ownership "$(cluster_fp)"   # ownership matches — would normally preserve
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=preserve" \
    "FORCE_SCYLLA_REINIT=true" \
    "I_UNDERSTAND_SCYLLA_DATA_WILL_BE_DESTROYED=true") || rc=$?
assert_exit "forced reinit exits 0" 0 "${rc}" "${output}"
# All data dirs wiped, including user keyspace.
assert_dir_absent "data dir wiped" "${TMP_ROOT}/scylla/data/system/topology-abc123"
assert_dir_absent "raft dir wiped" "${TMP_ROOT}/scylla/data/system/raft-def456"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 8: Fresh-join with no etcd_endpoints file → fails closed (no remote seed).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: Fresh-join with missing etcd_endpoints — fails closed (no remote seed)"
setup
# No etcd_endpoints file — SEED_IP will be self-only.
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=fresh-join" \
    "ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true") || rc=$?
assert_exit "missing-seed exits non-zero" 1 "${rc}" "${output}"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 9: Fresh-join with self-only seed in etcd_endpoints → fails closed.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: Fresh-join with self-only seed — fails closed"
setup
# etcd_endpoints contains only self (10.1.2.3 == NODE_IP).
echo "https://10.1.2.3:2379" > "${TMP_ROOT}/config/etcd_endpoints"
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=fresh-join" \
    "ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true") || rc=$?
assert_exit "self-only-seed exits non-zero" 1 "${rc}" "${output}"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# TEST 10: First-node bootstrap — self seed allowed with SCYLLA_BOOTSTRAP_INTENT=first-node.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10: First-node bootstrap — self-only seed allowed with bootstrap intent"
setup
# No remote peers — this is the cluster founder.
rc=0; output=$(run_script \
    "SCYLLA_INSTALL_INTENT=fresh-join" \
    "ALLOW_STALE_SCYLLA_REINIT_ON_JOIN=true" \
    "SCYLLA_BOOTSTRAP_INTENT=first-node") || rc=$?
assert_exit "bootstrap-intent exits 0" 0 "${rc}" "${output}"
teardown

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────────"

exit "${FAIL}"
