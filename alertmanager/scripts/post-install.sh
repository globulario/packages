#!/usr/bin/env bash
# post-install.sh — Alertmanager post-install: wire Prometheus to Alertmanager
# and install alert rules. Idempotent: safe to run multiple times.
set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/globular}"
NODE_IP="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
PROM_CFG="${STATE_DIR}/prometheus/prometheus.yml"
RULES_SRC="${PACKAGE_ROOT:-}/config/alertmanager/rules"
RULES_DST="${STATE_DIR}/prometheus/rules"

echo "[alertmanager/post-install] Starting Alertmanager post-install..."

# ── 1. Install alert rules ────────────────────────────────────────────────
# Source of truth: config/alertmanager/rules/ (from package payload)
# Runtime location: ${STATE_DIR}/prometheus/rules/ (where Prometheus reads them)
if [[ -d "${RULES_SRC}" ]]; then
    mkdir -p "${RULES_DST}"
    cp -a "${RULES_SRC}/." "${RULES_DST}/"
    chown -R globular:globular "${RULES_DST}" 2>/dev/null || true
    chmod 0750 "${RULES_DST}"
    echo "[alertmanager/post-install] ✓ Alert rules installed to ${RULES_DST}"
else
    echo "[alertmanager/post-install] No rules in package payload — skipping rules install"
fi

# ── 2. Wire Prometheus to Alertmanager ────────────────────────────────────
# Add rule_files + alerting sections if not already present.
if [[ ! -f "${PROM_CFG}" ]]; then
    echo "[alertmanager/post-install] Prometheus config not found at ${PROM_CFG} — skipping"
    exit 0
fi

CHANGED=false

# Add rule_files if missing
if ! grep -q "^rule_files:" "${PROM_CFG}" 2>/dev/null; then
    # Insert after evaluation_interval line
    sed -i "/evaluation_interval:/a\\
\\
rule_files:\\
  - \"${STATE_DIR}/prometheus/rules/*.yml\"" "${PROM_CFG}"
    echo "[alertmanager/post-install] ✓ Added rule_files to Prometheus config"
    CHANGED=true
fi

# Add alerting section if missing
if ! grep -q "^alerting:" "${PROM_CFG}" 2>/dev/null; then
    # Insert after rule_files block (find the line after rule_files entries)
    sed -i "/^rule_files:/,/^[a-z]/{
        /^[a-z]/i\\
\\
alerting:\\
  alertmanagers:\\
    - static_configs:\\
        - targets: [\"${NODE_IP}:9093\"]
    }" "${PROM_CFG}"
    # If sed didn't insert (no following top-level key), append before scrape_configs
    if ! grep -q "^alerting:" "${PROM_CFG}" 2>/dev/null; then
        sed -i "/^scrape_configs:/i\\
alerting:\\
  alertmanagers:\\
    - static_configs:\\
        - targets: [\"${NODE_IP}:9093\"]\\
" "${PROM_CFG}"
    fi
    echo "[alertmanager/post-install] ✓ Added alerting section to Prometheus config"
    CHANGED=true
fi

# Add alertmanager scrape target if missing
if ! grep -q 'job_name.*"alertmanager"' "${PROM_CFG}" 2>/dev/null; then
    # Insert as second scrape job (after prometheus self-monitoring)
    sed -i '/job_name.*"prometheus"/,/^[[:space:]]*$/!b; /^[[:space:]]*$/a\
  # Alertmanager metrics\
  - job_name: "alertmanager"\
    static_configs:\
      - targets: ["'"${NODE_IP}"':9093"]\
' "${PROM_CFG}"
    echo "[alertmanager/post-install] ✓ Added alertmanager scrape target"
    CHANGED=true
fi

# ── 3. Reload Prometheus if changes were made ─────────────────────────────
if [[ "${CHANGED}" == "true" ]]; then
    if systemctl is-active --quiet globular-prometheus.service 2>/dev/null; then
        if curl -sS -X POST http://127.0.0.1:9090/-/reload 2>/dev/null; then
            echo "[alertmanager/post-install] ✓ Prometheus reloaded"
        else
            echo "[alertmanager/post-install] ⚠ Prometheus reload failed — may need manual restart"
        fi
    fi
else
    echo "[alertmanager/post-install] Prometheus config already wired — no changes needed"
fi

echo "[alertmanager/post-install] ✓ Alertmanager post-install complete"
