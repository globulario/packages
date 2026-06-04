#!/bin/bash
# configure_test.sh — contract test for the scylla-manager-configure
# script embedded in specs/scylla_manager_service.yaml.
#
# This script is generated at install time by the install_files step
# in the spec yaml. The generated config MUST point scylla-manager at
# the Globular service cert / key — otherwise scylla-manager auto-
# generates a self-signed O=Scylla cert and the cluster-doctor rule
# scylla_manager.cluster_registered fails TLS verify against the
# Globular CA. Live regression 2026-06-03; see
# docs/operational-knowledge/incidents/sidecar-receipt-retirement-
# 2026-06-03.md (sibling chain) for the broader receipt-authority
# context.
#
# The spec yaml uses {{.StateDir}} for the cert paths so the script
# templates correctly at install time. We substitute {{.StateDir}}
# with a temp dir and run a synthesised version of the script with
# mocked CQL_HOST to verify the output yaml contains the required
# top-level keys.
#
# Run: bash configure_test.sh
# Exit: 0 = all passed, non-zero = number of failures
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${SCRIPT_DIR}/../specs/scylla_manager_service.yaml"

PASS=0
FAIL=0

require() {
    local label="$1" pattern="$2" file="$3"
    if grep -qE "$pattern" "$file"; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label  (pattern: $pattern)"
        echo "        file content:"; sed 's/^/          /' "$file"
        FAIL=$((FAIL+1))
    fi
}

require_fixed() {
    local label="$1" pattern="$2" file="$3"
    if grep -qF -- "$pattern" "$file"; then
        echo "  PASS  $label"
        PASS=$((PASS+1))
    else
        echo "  FAIL  $label  (literal: $pattern)"
        FAIL=$((FAIL+1))
    fi
}

echo "== spec exists =="
[ -f "$SPEC" ] || { echo "  FAIL  spec yaml not found at $SPEC"; exit 1; }
echo "  PASS  $SPEC"

echo
echo "== embedded script declares required TLS lines =="
# Static check: the heredoc content must include both TLS keys.
require_fixed "spec embeds 'https:' line"          'https: ${CQL_HOST}:5443'                                     "$SPEC"
require_fixed "spec embeds 'tls_cert_file' line"   'tls_cert_file: ${TLS_CERT}'                                  "$SPEC"
require_fixed "spec embeds 'tls_key_file' line"    'tls_key_file: ${TLS_KEY}'                                    "$SPEC"
require_fixed "TLS_CERT bound to StateDir"         'TLS_CERT="{{.StateDir}}/pki/issued/services/service.crt"'    "$SPEC"
require_fixed "TLS_KEY bound to StateDir"          'TLS_KEY="{{.StateDir}}/pki/issued/services/service.key"'     "$SPEC"

echo
echo "== simulated install: extract and run the heredoc with mocked inputs =="
# Extract the heredoc content (lines between 'cat > "$CFG" <<EOCONF' and 'EOCONF'),
# strip the 10-space leading indent the spec uses for yaml embedding, then
# substitute the template + shell variables and write to a temp CFG path.
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT
CFG="$TMP_DIR/scylla-manager.yaml"
MOCK_STATEDIR="/var/lib/globular"
MOCK_CQL_HOST="10.0.0.42"

# awk-extract the heredoc body, strip 10-space indent, substitute templates.
awk '
    /cat > "\$CFG" <<EOCONF/      { capture=1; next }
    capture && /^[[:space:]]+EOCONF[[:space:]]*$/ { capture=0; next }
    capture                       { print }
' "$SPEC" \
    | sed 's/^          //' \
    | sed "s|\${CQL_HOST}|$MOCK_CQL_HOST|g; s|\${TLS_CERT}|$MOCK_STATEDIR/pki/issued/services/service.crt|g; s|\${TLS_KEY}|$MOCK_STATEDIR/pki/issued/services/service.key|g" \
    > "$CFG"

echo "  generated config at $CFG"
sed 's/^/    /' "$CFG"

echo
echo "== generated config has required keys =="
require "http endpoint"           "^http: $MOCK_CQL_HOST:5080$"                                       "$CFG"
require "https endpoint"          "^https: $MOCK_CQL_HOST:5443$"                                      "$CFG"
require "tls_cert_file path"      "^tls_cert_file: $MOCK_STATEDIR/pki/issued/services/service\.crt$"  "$CFG"
require "tls_key_file path"       "^tls_key_file: $MOCK_STATEDIR/pki/issued/services/service\.key$"   "$CFG"
require "database hosts"          "^    - $MOCK_CQL_HOST$"                                            "$CFG"
require "database port 9042"      "^  port: 9042$"                                                    "$CFG"

echo
echo "== generated config parses as yaml =="
if python3 -c "import sys, yaml; d=yaml.safe_load(open('$CFG'));
expected = {'http', 'https', 'tls_cert_file', 'tls_key_file', 'database'}
missing  = expected - set(d.keys())
if missing: print('  FAIL  missing keys:', missing); sys.exit(1)
print('  PASS  yaml parses; top-level keys:', sorted(d.keys()))" ; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
fi

echo
echo "============================================================"
echo "Total: $((PASS+FAIL))   PASS: $PASS   FAIL: $FAIL"
exit $FAIL
