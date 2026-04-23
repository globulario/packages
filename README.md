# Globular Packages

**Frontend packages, web apps, package metadata, and bundled dependencies used by the Globular platform.**

This directory is the `packages/` workspace used by the `globular-admin` repository. It is not a single library. It is a collection of related package layers that support both the **operator-facing UI** and the **packaging/distribution metadata** used across the wider Globular project.

At a glance, this workspace contains:

- browser applications built with **Vite + TypeScript**
- shared frontend packages such as the **TypeScript SDK** and **component library**
- **package metadata** used to describe Globular services and infrastructure artifacts
- bundled third-party dependencies required by some package/install flows

## What this directory is for

The `packages/` tree serves two distinct purposes:

### 1. Frontend application workspace
It contains the packages used to build browser-based Globular apps:

- `web/` for the main admin console
- `media/` for the media-focused web application
- `sdk/` for TypeScript service access
- `components/` for reusable UI building blocks

### 2. Packaging metadata workspace
It also contains service metadata under `metadata/` for many Globular artifacts, including infrastructure, control-plane services, application services, and supporting tools.

That means this directory is where **UI/application code** and **package description data** meet.

## Directory structure

```text
packages/
├── web/                 # Main admin console app (@globular/admin-web)
├── media/               # Media-focused web app (@globular/media-web)
├── sdk/                 # TypeScript SDK for browser apps (@globular/sdk)
├── components/          # Reusable UI components (@globular/components)
├── metadata/            # Package metadata for services, infra, and tools
├── dependencies/        # Bundled third-party binaries/assets
└── scripts/             # Package-specific install/runtime scripts
```

## Frontend packages

### [`web/`](web/README.md)
The main **Globular admin console**.

Package name: `@globular/admin-web`

This app is the operator-facing UI for the platform. It is built with Vite and TypeScript and depends on the shared SDK and component packages.

Available commands:

```bash
pnpm --filter @globular/admin-web dev
pnpm --filter @globular/admin-web build
pnpm --filter @globular/admin-web preview
```

### [`media/`](media/README.md)
A separate **media web application**.

Package name: `@globular/media-web`

This app provides a focused media experience built on the same frontend stack and shared packages used by the admin UI.

Available commands:

```bash
pnpm --filter @globular/media-web dev
pnpm --filter @globular/media-web build
pnpm --filter @globular/media-web preview
```

### [`sdk/`](sdk/README.md)
The **TypeScript SDK** for browser-based Globular applications.

Package name: `@globular/sdk`

The SDK builds to `dist/` and exposes browser-facing service clients and shared helpers. It depends on generated web client artifacts from the backend repository.

Key details from the package:

- ESM package
- TypeScript build output in `dist/`
- test suite via **Vitest**
- depends on `globular-web-client` from `services/typescript/dist`

Available commands:

```bash
pnpm --filter @globular/sdk build
pnpm --filter @globular/sdk test
```

### [`components/`](components/README.md)
The **shared UI component library**.

Package name: `@globular/components`

This package exports reusable browser UI modules such as layouts, dialogs, menus, lists, tables, markdown rendering, split views, and wizard-style flows.

It is used by the admin and media applications and depends on the SDK and media workspace packages.

Available commands:

```bash
pnpm --filter @globular/components build
```

## Metadata packages

### `metadata/`
This directory contains **package metadata** for a large part of the Globular platform.

Examples include:

- control plane: `cluster-controller`, `node-agent`, `workflow`, `repository`
- infrastructure: `etcd`, `envoy`, `prometheus`, `alertmanager`, `minio`, `scylladb`
- core services: `authentication`, `rbac`, `dns`, `event`, `file`, `log`, `resource`
- app/services: `blog`, `catalog`, `conversation`, `media`, `search`, `storage`, `title`, `torrent`
- supporting tools: `globular-cli`, `mcp`, `ffmpeg`, `yt-dlp`, `rclone`, `restic`, `sha256sum`

Each metadata package contains a `package.json` that describes the corresponding artifact.

This part of the workspace is important because Globular is not only a UI stack. It is also a **packaged service platform** with explicit artifact descriptions.

## Dependencies and scripts

### `dependencies/`
This directory contains bundled external assets used by package/install flows.

In the extracted workspace you provided, it includes:

- `restic-0.18.1/restic`

### `scripts/`
Package-specific scripting support.

In the extracted workspace you provided, it includes:

- `scripts/scylladb/post-install.sh`

## How this fits into the wider project

This directory is part of the `globular-admin` repository, which is the **frontend/application layer** of Globular.

Related repositories:

- **Globular**: top-level platform entry point and project overview
- **services**: backend services, control plane, protobuf contracts, generated clients, and installable releases
- **globular-admin**: admin UI, media app, SDK, components, and workspace docs
- **globular-quickstart**: simulation and test environment
- **globular-installer**: installer/bootstrap implementation used by packaged install flows

## Development notes

This workspace assumes a **pnpm workspace** environment and depends on sibling packages and generated client artifacts from the backend repository.

Typical workflow:

```bash
pnpm install
pnpm --filter @globular/admin-web dev
pnpm --filter @globular/media-web dev
pnpm --filter @globular/sdk test
pnpm --filter @globular/components build
```

## Who should read this directory

This `packages/` directory is useful for:

- frontend developers working on the admin console or media app
- developers building browser apps on top of Globular
- contributors working on the shared SDK or reusable UI elements
- platform contributors managing package metadata for services and infrastructure

## See also

- [`web/README.md`](web/README.md)
- [`media/README.md`](media/README.md)
- [`sdk/README.md`](sdk/README.md)
- [`components/README.md`](components/README.md)
