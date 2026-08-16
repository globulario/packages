#!/usr/bin/env python3
"""validate-package-identity.py — build-time package identity consistency gate.

WHY THIS EXISTS
---------------
A package's identity — its binary name and its kind — is declared in multiple
places: registry.yaml, metadata/<name>/specs/*.yaml, metadata/<name>/package.json,
the spec's inline systemd ExecStart, the spec's start_services.binaries map, and
metadata/<name>/systemd/<unit>. Nothing enforced
that these agreed, so they drifted.

The mcp binary ships as "mcp_server" (the Go build for ./mcp collides with the package
dir name). The spec kept drifting back to "mcp" — fixed by hand 5+ times. A fresh build
from a spec that says "mcp" produces ExecStart=/usr/lib/globular/bin/mcp, which does not
exist, so start-services never converges and Day-0 reports "version:mcp not installed".

This gate checks every metadata-local spec plus package.json, awareness.yaml, and the
systemd unit against registry.yaml. registry.yaml is the SOLE author of kind; this gate
is source-vs-mirror. The former
CATALOG_KIND photocopy (a hand-mirror of component_catalog.go) was REMOVED (Slice 2) —
the registry↔component_catalog kind agreement is enforced services-side by
`make check-package-kinds` + package_kind_registry_consistency_test.go, not duplicated here.
Any disagreement fails the build loud.

Do NOT relax a check to make a build pass, and never edit registry.yaml to match a
drifting file — fix the drifting file to match the authority.

USAGE
    python3 scripts/validate-package-identity.py [--repo-root <path>]
Exit 0 = all consistent; exit 1 = at least one mismatch (details on stderr).
"""

import json
import os
import re
import sys
import yaml

VALID_KINDS = {"service", "infrastructure", "command", "application"}

# Kind authority (Slice 2): registry.yaml.kind is the SOLE author. The former
# CATALOG_KIND dict (a photocopy of component_catalog.go, "MUST mirror …") lived here
# and was itself one of the drifting copies of "kind" — it has been REMOVED so the
# guardian cannot hold a photocopy. This gate validates the packages-repo MIRRORS
# (package.json type, awareness.yaml package_kind, spec metadata.kind, systemd binary)
# DIRECTLY against registry.yaml (source-vs-mirror). The registry↔component_catalog.go
# agreement is enforced services-side (make check-package-kinds +
# package_kind_registry_consistency_test.go). Do NOT reintroduce a hardcoded kind map
# (forbidden_fix: hardcode_package_kind_classification_outside_canonical_registry).
# See services docs/design/package-classification-single-source.md.

EXECSTART_BIN_RE = re.compile(r"ExecStart\s*=\s*\S*?/bin/([A-Za-z0-9_.-]+)")
PKILL_X_RE = re.compile(r"pkill\b[^\n]*?-x\s+([A-Za-z0-9_.-]+)")

# Identity proof (invariant identity.has_single_canonical_source_and_is_immutable +
# forbidden_fix:recompute_identity_from_secondary_source): every package must carry a
# stable, DECLARED, verifiable identity — never a silent empty checksum that a
# reader would "recover" by hashing whatever is on disk. Shipped-binary packages
# carry it implicitly (entrypoint + build-computed entrypoint_checksum). A package
# whose entrypoint is "none" (noop: curl/wrapper, .deb, OS-repo) installs a binary
# the build never sees, so it MUST declare an explicit identity{} block naming the
# proof mode:
#   binary_sha256 — a pinned sha256 of the installed entrypoint at a fixed path
#                   (the node-agent re-hashes the path and compares). Requires
#                   `checksum` (sha256) + absolute `installed_path`.
#   version       — the package version IS the identity (vendor tree/symlink or an
#                   OS/deb binary whose bytes vary by distro); verified via the
#                   runtime's own version report. Requires a non-empty version.
VALID_IDENTITY_PROOFS = {"binary_sha256", "version"}
SHA256_RE = re.compile(r"^(sha256:)?[0-9a-f]{64}$")


def check_identity(errors, name, pj):
    entrypoint = (pj.get("entrypoint") or "").strip().lower()
    ident = pj.get("identity")
    if entrypoint and entrypoint != "none":
        # Shipped-binary package: identity is the entrypoint binary + its
        # build-computed checksum. An explicit identity{} block is optional, but if
        # present it must agree (binary_sha256).
        if isinstance(ident, dict):
            proof = (ident.get("proof") or "").strip()
            if proof and proof != "binary_sha256":
                fail(errors, f"{name}: entrypoint='{entrypoint}' is a shipped binary but "
                             f"identity.proof='{proof}' — must be 'binary_sha256'.")
        return
    # entrypoint is "none"/absent → noop package: an explicit identity{} block is REQUIRED.
    if not isinstance(ident, dict):
        fail(errors, f"{name}: entrypoint 'none' but no identity{{}} block declared. Every "
                     f"package needs a stable, verifiable identity — declare identity.proof "
                     f"(binary_sha256 | version). A missing identity is the empty-checksum hole "
                     f"that lets applied_hash validation silently pass on nothing "
                     f"(identity.has_single_canonical_source_and_is_immutable).")
        return
    proof = (ident.get("proof") or "").strip()
    if proof not in VALID_IDENTITY_PROOFS:
        fail(errors, f"{name}: identity.proof='{proof}' invalid — must be one of "
                     f"{sorted(VALID_IDENTITY_PROOFS)}.")
        return
    if proof == "binary_sha256":
        cksum = (ident.get("checksum") or "").strip()
        if not SHA256_RE.match(cksum):
            fail(errors, f"{name}: identity.proof=binary_sha256 requires a non-empty sha256 "
                         f"`checksum` (got '{cksum}'). It must equal sha256(installed binary).")
        if not (ident.get("installed_path") or "").strip().startswith("/"):
            fail(errors, f"{name}: identity.proof=binary_sha256 requires an absolute "
                         f"`installed_path` the node-agent can re-hash.")
    elif proof == "version":
        if not (pj.get("version") or "").strip():
            fail(errors, f"{name}: identity.proof=version requires a non-empty package version.")


def fail(errors, msg):
    errors.append(msg)
    print(f"ERROR {msg}", file=sys.stderr)


def load_registry(repo_root):
    path = os.path.join(repo_root, "registry.yaml")
    with open(path) as f:
        doc = yaml.safe_load(f)
    entries = doc.get("packages", doc) if isinstance(doc, dict) else doc
    out = {}
    for e in entries:
        if isinstance(e, dict) and "name" in e:
            out[e["name"]] = {
                "binary": (e.get("binary") or "").strip(),
                "kind": (e.get("kind") or "").strip().lower(),
            }
    return out


def check_binary(errors, name, where, got, want):
    for v in (got if isinstance(got, list) else [got]):
        if v and v != want:
            fail(errors, f"{name}: binary mismatch in {where}: got '{v}', registry.yaml says '{want}'.\n"
                         f"      registry.yaml is the authority — align {where} to '{want}' "
                         f"(do NOT change registry to match the drift).")


def check_spec(errors, registry, spec_path, repo_root):
    raw = open(spec_path).read()
    doc = yaml.safe_load(raw) or {}
    meta = doc.get("metadata", {}) or {}
    name = (meta.get("name") or "").strip()
    rel = os.path.relpath(spec_path, repo_root)
    if not name:
        fail(errors, f"{rel}: spec has no metadata.name — cannot bind it to a registry package")
        return
    # Specs declare names with underscores (matching the filename); the registry
    # uses the canonical hyphenated package name. Normalize before lookup.
    lookup = name.replace("_", "-")
    reg = registry.get(lookup)
    if reg is None:
        fail(errors, f"{rel}: metadata.name='{name}' has no registry.yaml entry")
        return
    name = lookup
    want_bin, want_kind = reg["binary"], reg["kind"]

    entrypoint = os.path.basename((meta.get("entrypoint") or "").strip())
    binaries = []
    for step in doc.get("steps", []) or []:
        if isinstance(step, dict) and isinstance(step.get("binaries"), dict):
            binaries.extend(str(v).strip() for v in step["binaries"].values())

    if want_bin:
        check_binary(errors, name, f"{rel} metadata.entrypoint", entrypoint, want_bin)
        check_binary(errors, name, f"{rel} ExecStart", EXECSTART_BIN_RE.findall(raw), want_bin)
        check_binary(errors, name, f"{rel} start_services.binaries", binaries, want_bin)
        check_binary(errors, name, f"{rel} ExecStartPre pkill -x", PKILL_X_RE.findall(raw), want_bin)
    spec_kind = (meta.get("kind") or "").strip().lower()
    if want_kind and spec_kind and spec_kind != want_kind:
        fail(errors, f"{name}: kind mismatch — {rel} metadata.kind='{spec_kind}' "
                     f"vs registry.yaml kind='{want_kind}'.")


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    args = sys.argv[1:]
    while args:
        if args[0] == "--repo-root":
            repo_root = os.path.abspath(args[1]); args = args[2:]
        else:
            print(f"Unknown arg: {args[0]}", file=sys.stderr); return 2

    registry = load_registry(repo_root)
    errors = []
    spec_count = 0

    print("=== Globular Package Identity Validator ===")
    print(f"repo-root: {repo_root}")
    print(f"registry:  {len(registry)} packages\n")

    # registry.yaml is the SOLE author of kind — validate only that it is a known kind.
    # (The former registry-vs-CATALOG_KIND photocopy check was removed in Slice 2; the
    # registry↔component_catalog.go agreement is enforced services-side.)
    for name, reg in registry.items():
        if reg["kind"] and reg["kind"] not in VALID_KINDS:
            fail(errors, f"{name}: registry.yaml kind '{reg['kind']}' is not valid {sorted(VALID_KINDS)}")

    # Every metadata-local spec is checked against registry by its own declared
    # metadata.name.
    spec_dirs = []
    meta_root = os.path.join(repo_root, "metadata")
    if os.path.isdir(meta_root):
        for name in sorted(os.listdir(meta_root)):
            d = os.path.join(meta_root, name, "specs")
            if os.path.isdir(d):
                spec_dirs.append(d)
    for d in spec_dirs:
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".yaml"):
                spec_count += 1
                try:
                    check_spec(errors, registry, os.path.join(d, f), repo_root)
                except Exception as exc:  # noqa: BLE001
                    fail(errors, f"{os.path.join(d, f)}: cannot parse: {exc}")

    # package.json + standalone systemd unit per metadata dir.
    if os.path.isdir(meta_root):
        for name in sorted(os.listdir(meta_root)):
            reg = registry.get(name)
            if reg is None:
                continue
            want_bin, want_kind = reg["binary"], reg["kind"]
            pj_path = os.path.join(meta_root, name, "package.json")
            if os.path.isfile(pj_path):
                pj = json.load(open(pj_path))
                check_identity(errors, name, pj)
                if want_bin:
                    check_binary(errors, name, "package.json.entrypoint",
                                 os.path.basename((pj.get("entrypoint") or "").strip()), want_bin)
                pj_type = (pj.get("type") or "").strip().lower()
                if want_kind and pj_type and pj_type != want_kind:
                    fail(errors, f"{name}: kind mismatch — package.json.type='{pj_type}' "
                                 f"vs registry.yaml kind='{want_kind}'.")
                spec_rel = (pj.get("defaults") or {}).get("spec") or ""
                if spec_rel:
                    metadata_spec = os.path.join(meta_root, name, spec_rel)
                    if not os.path.isfile(metadata_spec):
                        fail(errors, f"{name}: package.json defaults.spec='{spec_rel}' but metadata-local spec is missing.\n"
                                     f"      Expected {os.path.relpath(metadata_spec, repo_root)}.")
            # awareness.yaml package_kind mirror (copy #3) — gated against registry.
            aw_path = os.path.join(meta_root, name, "awareness.yaml")
            if os.path.isfile(aw_path):
                try:
                    aw = yaml.safe_load(open(aw_path)) or {}
                except Exception as exc:  # noqa: BLE001 - report and continue
                    aw = {}
                    fail(errors, f"{name}: cannot parse awareness.yaml: {exc}")
                aw_kind = str(aw.get("package_kind") or "").strip().lower()
                if want_kind and aw_kind and aw_kind != want_kind:
                    fail(errors, f"{name}: kind mismatch — awareness.yaml package_kind='{aw_kind}' "
                                 f"vs registry.yaml kind='{want_kind}'.")
            unit_dir = os.path.join(meta_root, name, "systemd")
            if os.path.isdir(unit_dir) and want_bin:
                for f in os.listdir(unit_dir):
                    if f.endswith(".service"):
                        raw = open(os.path.join(unit_dir, f)).read()
                        rel = os.path.relpath(os.path.join(unit_dir, f), repo_root)
                        check_binary(errors, name, f"{rel} ExecStart", EXECSTART_BIN_RE.findall(raw), want_bin)
                        check_binary(errors, name, f"{rel} ExecStartPre pkill -x", PKILL_X_RE.findall(raw), want_bin)

    print(f"\n=== Summary: {spec_count} spec file(s) checked, {len(errors)} error(s) ===")
    if errors:
        print("FAILED — package identity drift detected (see ERROR lines above).", file=sys.stderr)
        return 1
    print("PASSED — every spec/package.json/unit agrees with registry.yaml.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
