#!/usr/bin/env bash
# validate-package-identity_test.sh — regression test for the kind source-vs-mirror gate.
#
# Slice 2 (package-classification-single-source): registry.yaml.kind is the SOLE
# author of package kind. This test proves the gate is source-vs-mirror, fail-closed:
#   - an aligned fixture passes (exit 0);
#   - a downstream kind mirror that DISAGREES with registry.yaml fails (exit 1),
#     for each of the three mirrors: package.json `type`, awareness.yaml
#     `package_kind`, and the spec's metadata.kind.
#
# This is the regression for "the guardian must not hold a photocopy": the removed
# CATALOG_KIND dict could co-drift; these cases lock the registry-as-source behaviour.
#
# Run: bash scripts/validate-package-identity_test.sh   (exit 0 = all cases pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$HERE/validate-package-identity.py"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PKG="$ROOT/metadata/foo"
mkdir -p "$PKG/specs"

# Fixture: one infrastructure package "foo"; binary "foo" is consistent everywhere
# so only the KIND mirrors vary across cases (no binary-mismatch noise).
cat > "$ROOT/registry.yaml" <<'YAML'
packages:
  - name: foo
    binary: foo
    kind: infrastructure
    systemd_unit: globular-foo.service
YAML

write_good() {
  printf '{"entrypoint": "bin/foo", "type": "infrastructure"}\n' > "$PKG/package.json"
  printf 'package: foo\npackage_kind: infrastructure\n'          > "$PKG/awareness.yaml"
  printf 'metadata:\n  name: foo\n  kind: infrastructure\n  entrypoint: bin/foo\n' > "$PKG/specs/foo_service.yaml"
}

OUT="$ROOT/out.txt"
fails=0
run() { python3 "$VALIDATOR" --repo-root "$ROOT" >"$OUT" 2>&1; echo $?; }

assert_pass() {
  local label="$1"; write_good; local rc; rc=$(run)
  if [ "$rc" != 0 ]; then echo "FAIL[$label]: expected pass, got exit $rc"; cat "$OUT"; fails=$((fails+1));
  else echo "ok[$label]: aligned fixture passes"; fi
}

# assert_fail expects the caller to have already written the drifting mirror.
assert_fail() {
  local label="$1" needle="$2"; local rc; rc=$(run)
  if [ "$rc" != 1 ]; then echo "FAIL[$label]: expected exit 1, got $rc"; cat "$OUT"; fails=$((fails+1));
  elif ! grep -qF "$needle" "$OUT"; then echo "FAIL[$label]: exit 1 but message missing '$needle'"; cat "$OUT"; fails=$((fails+1));
  else echo "ok[$label]: drift caught ($needle)"; fi
}

# 0. aligned fixture passes.
assert_pass baseline

# 1. package.json type disagrees with registry.
write_good; printf '{"entrypoint": "bin/foo", "type": "service"}\n' > "$PKG/package.json"
assert_fail package.json "package.json.type='service'"

# 2. awareness.yaml package_kind disagrees with registry.
write_good; printf 'package: foo\npackage_kind: service\n' > "$PKG/awareness.yaml"
assert_fail awareness.yaml "awareness.yaml package_kind='service'"

# 3. spec metadata.kind disagrees with registry.
write_good; printf 'metadata:\n  name: foo\n  kind: service\n  entrypoint: bin/foo\n' > "$PKG/specs/foo_service.yaml"
assert_fail spec "metadata.kind='service'"

if [ "$fails" -ne 0 ]; then echo "=== $fails case(s) FAILED ==="; exit 1; fi
echo "=== all kind source-vs-mirror cases passed ==="
