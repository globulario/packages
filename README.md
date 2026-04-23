# Globular Packages

**Package metadata, bundled dependencies, and install scripts for Globular artifacts.**

This directory contains the package description layer used to build, publish, install, and validate Globular artifacts.

It is **not** the frontend workspace and it is **not** the service source tree.

Instead, this package set defines what Globular can ship and install:
- service packages
- infrastructure packages
- command-line tool packages
- bundled third-party dependencies
- package-specific install hooks

## What lives here

```text
packages/
├── metadata/                 # package descriptors for Globular artifacts
├── dependencies/             # bundled external binaries/assets
└── scripts/                  # package-specific install/runtime scripts
```

## `metadata/`

The `metadata/` directory contains one package folder per artifact.  
Each artifact includes a `package.json` describing things such as:

- package type
- name
- version
- target platform
- publisher
- entrypoint
- default spec path
- profiles
- systemd unit
- health-check unit/port
- entrypoint checksum

These metadata files are the declarative description of what a package is and how it should be installed or supervised.

### Package types found in this archive

- **34 service packages**
- **12 infrastructure packages**
- **10 command packages**

### Service packages

These are Globular services that run inside the platform:

- `ai-executor`
- `ai-memory`
- `ai-router`
- `ai-watcher`
- `authentication`
- `backup-manager`
- `blog`
- `catalog`
- `cluster-controller`
- `cluster-doctor`
- `conversation`
- `discovery`
- `dns`
- `echo`
- `event`
- `file`
- `gateway`
- `ldap`
- `log`
- `mail`
- `media`
- `monitoring`
- `node-agent`
- `persistence`
- `rbac`
- `repository`
- `resource`
- `search`
- `sql`
- `storage`
- `title`
- `torrent`
- `workflow`
- `xds`

### Infrastructure packages

These are supporting runtime dependencies and infrastructure components:

- `alertmanager`
- `envoy`
- `etcd`
- `keepalived`
- `mcp`
- `minio`
- `node-exporter`
- `prometheus`
- `scylla-manager`
- `scylla-manager-agent`
- `scylladb`
- `sidekick`

### Command packages

These are commands or tools shipped as installable artifacts:

- `claude`
- `etcdctl`
- `ffmpeg`
- `globular-cli`
- `mc`
- `rclone`
- `restic`
- `sctool`
- `sha256sum`
- `yt-dlp`

## Example metadata fields

A typical package descriptor in this archive includes fields like:

```json
{
  "type": "service",
  "name": "cluster-controller",
  "version": "0.0.1",
  "platform": "linux_amd64",
  "publisher": "core@globular.io",
  "entrypoint": "bin/cluster_controller_server",
  "defaults": {
    "configDir": "",
    "spec": "specs/cluster_controller_service.yaml"
  },
  "profiles": ["control-plane"],
  "systemd_unit": "globular-cluster-controller.service",
  "health_check_unit": "globular-cluster-controller.service",
  "entrypoint_checksum": "sha256:..."
}
```

This shows the purpose of the directory well: it is the **artifact-definition layer** used by the package/install pipeline.

## `dependencies/`

This directory contains bundled third-party assets required by some packages.

In the archive you provided, it contains:

- `dependencies/restic-0.18.1/restic`

That indicates this package set can also carry pre-bundled external tools instead of relying only on system packages or remote downloads.

## `scripts/`

This directory contains package-specific scripts used during install or post-install flows.

In the archive you provided, it contains:

- `scripts/scylladb/post-install.sh`

This means some artifacts need additional setup steps beyond dropping files on disk, and those hooks live here.

## What this directory is for in the Globular project

This package set matters because Globular is not only source code. It is a **packaged platform**.

This directory is where installable artifacts become explicit and machine-readable.

It supports things like:

- package publication
- repository ingestion
- install workflows
- validation of entrypoints and checksums
- package categorization by type and role
- service supervision mapping through systemd units
- profile-aware installation

## Relationship to the other repositories

In the wider Globular project:

- **`services`** contains most backend service source code and installable releases
- **`Globular`** is the umbrella/platform entry-point repository
- **`globular-installer`** contains installer/bootstrap implementation used by packaged install flows
- **`globular-admin`** contains the frontend/admin/UI layer

This `packages/` content sits underneath that, as the **artifact metadata layer**.

## Typical use

People working in this directory are usually:

- defining or updating package metadata
- adding new installable artifacts
- adjusting systemd/service wiring
- adding bundled dependencies
- attaching post-install hooks

## Notes

- These package descriptors target **Linux amd64** in the archive you provided.
- The metadata is intentionally declarative and artifact-oriented.
- This directory is closer to **distribution engineering** than to app development.

## License

See the repository license and the licenses declared by the individual artifacts where applicable.
