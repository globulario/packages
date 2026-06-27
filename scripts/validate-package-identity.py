#!/usr/bin/env python3
"""validate-package-identity.py — build-time package identity consistency gate.

WHY THIS EXISTS
---------------
A package's identity — its binary name and its kind — is declared in up to six
places: registry.yaml, metadata/<name>/package.json, the spec's metadata block,
the spec's inline systemd ExecStart, the spec's start_services.binaries map, and
the standalone metadata/<name>/systemd/<unit> file. Nothing enforced that these
agreed, so they drifted.

The mcp binary was named "mcp" in the spec while package.json/registry said
"mcp_server" — fixed by hand at least five times (commits 27d9bf6, 94ffdda, ...),
then silently RE-broken on 2026-06-20 when the spec source-of-truth consolidation
resolved the duplicate toward the stale copy. A fresh Day-0 then failed because
ExecStart=/usr/lib/globular/bin/mcp pointed at a binary that ships as mcp_server,
so start-services never converged and the controller reported
"version:mcp not installed".

This gate makes that class of drift impossible to ship: registry.yaml is the
authority; every other declaration of the same package's binary and kind MUST
agree with it, or the build fails loud.

Related rule (meta): half_done_must_not_look_done / identity_must_be_single_source.
Do NOT relax a check to make a build pass — fix the drifting file.

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

# NOTE (package-classification single-source, Slice 2): the former hardcoded
# CATALOG_KIND map lived here as a *photocopy* of component_catalog.go ("MUST mirror
# component_catalog.go") — itself one of the eight drifting copies of "kind". It has
# been REMOVED. registry.yaml is the single author; the registry-vs-runtime-classifier
# (component_catalog.go) check now lives mechanically in the services repo as
# TestComponentCatalogKindMatchesRegistry, which compares component_catalog.go against a
# build-time projection of THIS registry.yaml (golang/packagekind). This validator keeps
# enforcing that the packages-repo COPIES — package.json type, awareness.yaml
# package_kind, spec metadata.kind, systemd binary — agree with registry.yaml.
# See docs/design/package-classification-single-source.md (services repo).
# Do NOT reintroduce a hardcoded kind map here (forbidden_fix in the scar).

# Binary references inside a spec/unit live in literal block scalars, so they are
# extracted from raw text rather than the parsed YAML tree.
EXECSTART_BIN_RE = re.compile(r"ExecStart\s*=\s*\S*?/bin/([A-Za-z0-9_.-]+)")
PKILL_X_RE = re.compile(r"pkill\b[^\n]*?-x\s+([A-Za-z0-9_.-]+)")


def fail(errors, msg):
    errors.append(msg)
    print(f"ERROR {msg}", file=sys.stderr)


def load_registry(repo_root):
    """Return {name: {'binary': str, 'kind': str, 'unit': str}} from registry.yaml."""
    path = os.path.join(repo_root, "registry.yaml")
    with open(path) as f:
        doc = yaml.safe_load(f)
    # registry.yaml is a mapping with a 'packages' list, or a bare list — handle both.
    entries = doc.get("packages", doc) if isinstance(doc, dict) else doc
    out = {}
    for e in entries:
        if not isinstance(e, dict) or "name" not in e:
            continue
        name = e["name"]
        out[name] = {
            "binary": (e.get("binary") or "").strip(),
            "kind": (e.get("kind") or "").strip().lower(),
            "unit": (e.get("systemd_unit") or "").strip(),
        }
    return out


def spec_facts(spec_path):
    """Extract identity facts from a spec yaml. Returns dict or None on parse error."""
    raw = open(spec_path).read()
    doc = yaml.safe_load(raw)
    meta = (doc or {}).get("metadata", {}) or {}
    entrypoint = (meta.get("entrypoint") or "").strip()
    binaries = []  # values of every start_services.binaries map
    for step in (doc or {}).get("steps", []) or []:
        if isinstance(step, dict) and isinstance(step.get("binaries"), dict):
            binaries.extend(str(v).strip() for v in step["binaries"].values())
    return {
        "kind": (meta.get("kind") or "").strip().lower(),
        "entrypoint_bin": os.path.basename(entrypoint) if entrypoint else "",
        "execstart_bins": EXECSTART_BIN_RE.findall(raw),
        "pkill_targets": PKILL_X_RE.findall(raw),
        "binaries_map": binaries,
    }


def unit_facts(unit_path):
    raw = open(unit_path).read()
    return {
        "execstart_bins": EXECSTART_BIN_RE.findall(raw),
        "pkill_targets": PKILL_X_RE.findall(raw),
    }


def check_binary(errors, name, where, got, want):
    """got may be a single value or a list; each must equal want."""
    values = got if isinstance(got, list) else [got]
    for v in values:
        if v and v != want:
            fail(
                errors,
                f"{name}: binary mismatch in {where}: got '{v}', registry.yaml says '{want}'.\n"
                f"      registry.yaml is the authority — align {where} to '{want}' "
                f"(do NOT change registry to match the drift).",
            )


def main():
    repo_root = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..")
    )
    args = sys.argv[1:]
    while args:
        if args[0] == "--repo-root":
            repo_root = os.path.abspath(args[1])
            args = args[2:]
        else:
            print(f"Unknown arg: {args[0]}", file=sys.stderr)
            return 2

    registry = load_registry(repo_root)
    metadata_dir = os.path.join(repo_root, "metadata")
    errors = []
    checked = 0

    print("=== Globular Package Identity Validator ===")
    print(f"repo-root: {repo_root}")
    print(f"registry:  {len(registry)} packages\n")

    for name in sorted(os.listdir(metadata_dir)):
        pkg_dir = os.path.join(metadata_dir, name)
        if not os.path.isdir(pkg_dir):
            continue

        reg = registry.get(name)
        if reg is None:
            fail(errors, f"{name}: has metadata/ dir but no registry.yaml entry "
                         f"(registry is the package index — add it).")
            continue

        want_bin = reg["binary"]
        want_kind = reg["kind"]
        if want_kind and want_kind not in VALID_KINDS:
            fail(errors, f"{name}: registry.yaml kind '{want_kind}' is not valid {sorted(VALID_KINDS)}")
        # (registry-vs-component_catalog.go cross-check moved to the services repo:
        # TestComponentCatalogKindMatchesRegistry — see the CATALOG_KIND removal note above.)

        # --- package.json ---
        pj_path = os.path.join(pkg_dir, "package.json")
        if os.path.isfile(pj_path):
            pj = json.load(open(pj_path))
            pj_bin = os.path.basename((pj.get("entrypoint") or "").strip())
            pj_type = (pj.get("type") or "").strip().lower()
            if want_bin:
                check_binary(errors, name, "package.json.entrypoint", pj_bin, want_bin)
            if want_kind and pj_type and pj_type != want_kind:
                fail(errors, f"{name}: kind mismatch — package.json.type='{pj_type}' "
                             f"vs registry.yaml kind='{want_kind}'.")

        # --- awareness.yaml (package_kind, copy #3 — previously ungated) ---
        aw_path = os.path.join(pkg_dir, "awareness.yaml")
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

        # --- spec ---
        specs = []
        spec_dir = os.path.join(pkg_dir, "specs")
        if os.path.isdir(spec_dir):
            specs = [os.path.join(spec_dir, f) for f in os.listdir(spec_dir)
                     if f.endswith(".yaml")]
        for spec_path in specs:
            try:
                sf = spec_facts(spec_path)
            except Exception as exc:  # noqa: BLE001 - report and continue
                fail(errors, f"{name}: cannot parse {os.path.relpath(spec_path, repo_root)}: {exc}")
                continue
            rel = os.path.relpath(spec_path, repo_root)
            if want_bin:
                check_binary(errors, name, f"{rel} metadata.entrypoint", sf["entrypoint_bin"], want_bin)
                check_binary(errors, name, f"{rel} ExecStart", sf["execstart_bins"], want_bin)
                check_binary(errors, name, f"{rel} start_services.binaries", sf["binaries_map"], want_bin)
                check_binary(errors, name, f"{rel} ExecStartPre pkill -x", sf["pkill_targets"], want_bin)
            if want_kind and sf["kind"] and sf["kind"] != want_kind:
                fail(errors, f"{name}: kind mismatch — {rel} metadata.kind='{sf['kind']}' "
                             f"vs registry.yaml kind='{want_kind}'.")

        # --- standalone systemd unit(s) ---
        unit_dir = os.path.join(pkg_dir, "systemd")
        if os.path.isdir(unit_dir) and want_bin:
            for f in os.listdir(unit_dir):
                if not f.endswith(".service"):
                    continue
                uf = unit_facts(os.path.join(unit_dir, f))
                rel = os.path.relpath(os.path.join(unit_dir, f), repo_root)
                check_binary(errors, name, f"{rel} ExecStart", uf["execstart_bins"], want_bin)
                check_binary(errors, name, f"{rel} ExecStartPre pkill -x", uf["pkill_targets"], want_bin)

        checked += 1

    print(f"\n=== Summary: {checked} packages checked, {len(errors)} error(s) ===")
    if errors:
        print("FAILED — package identity drift detected (see ERROR lines above).", file=sys.stderr)
        return 1
    print("PASSED — every package's binary name and kind agree with registry.yaml.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
