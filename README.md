# immich-docker

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

One-command Immich for homelab beginners — official images, backup-before-update.

![`./manage.sh` control center](docs/manage-demo.gif)

## Install

```bash
git clone https://github.com/johnycsf/immich-docker.git
cd immich-docker
chmod +x manage.sh
./manage.sh
```

`./manage.sh` opens a **↑/↓ menu** with a `>` cursor (j/k and Enter also work). Open the URL the script prints, create your admin account, then use the Immich mobile apps.

Uses **Immich’s official images** from GHCR (`immich-server`, `immich-machine-learning`, Immich Postgres with VectorChord) plus **Valkey** — the Redis-compatible cache Immich ships in their [official install compose](https://docs.immich.app/install/docker-compose). No LinuxServer or unofficial Immich forks.

Kubernetes version: [immich-k8s](https://github.com/johnycsf/immich-k8s)

## Why this repo (not just another compose file)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools
- Safe **`./manage.sh update`** with automatic pre-update backup
- Incremental hardlink **`./manage.sh backup`** + restore
- **Official upstream images only**

## What you need

- A Linux host (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) or macOS with Homebrew
- `sudo` so `./manage.sh` can install missing tools (Docker, curl, openssl, rsync, …)
- Enough disk for your data

## Customize

Edit `.env` (created from `.env.example`):

| Variable | Purpose |
|----------|---------|
| `IMMICH_PORT` | Published + listen port (default `2283`; Immich binds to this inside the container) |
| `IMMICH_VERSION` | Immich tag (default `v3`; pin e.g. `v3.1.0` if you prefer) |
| `TZ` | Timezone |
| `UPLOAD_LOCATION` | Photo library on disk (default `./data/library`) |
| `DB_DATA_LOCATION` | Postgres files (default `./data/postgres`) |
| `DB_PASSWORD` | Database password (auto-generated; alphanumeric only) |

## Update

```bash
./manage.sh update
```

Before updating, the script runs `./manage.sh backup` into `./backups` (Postgres dump + incremental library hardlinks). Afterward it asks whether to keep that snapshot and how many copies to retain.

## Backup and restore

Prefer an external drive or NAS (libraries are large; hardlinks need one filesystem):

```bash
./manage.sh backup --dest /mnt/backup --keep 3
# optional: also snapshot ML model cache
./manage.sh backup --dest /mnt/backup --keep 3 --include-model-cache
```

Each run writes `/mnt/backup/immich-docker/snapshots/...`.

Restore (this machine or a new one after `./manage.sh` / with compose present):

```bash
./manage.sh backup --restore --from /mnt/usb/immich-docker-backups
# or a local snapshot tree:
./manage.sh backup --restore --from ./backups
```

Each snapshot includes `SHA256SUMS` / `snapshot_sha256` for dumps and config. The photo library uses a fast size+path fingerprint (full per-file hashing of hundreds of GB would thrash the disk). Restore **warns** if integrity looks wrong but does not abort.

**Database safety:** Postgres is backed up with a verified logical `pg_dump` — the live database files are never rsync’d while running.

## Uninstall

```bash
docker compose down
# optional: delete local data (DESTROYS your library)
rm -rf data
```

Or use **Uninstall** in `./manage.sh`.

## Notes

- Follow Immich release notes when jumping major versions.
- Hardware acceleration for ML/transcoding is optional; see Immich docs and the commented `hwaccel` examples in upstream compose if you need them later.

## Host ports

During `./manage.sh` (or Manage → Install / reconfigure), the script checks whether default host ports are free, lets you keep the defaults or choose different ports, and saves them in `.env`. Re-running install keeps your current ports unless you change them.

Non-interactive: set the port variables in `.env` (or the environment) and use `SKIP_PORT_PROMPTS=1`.

Defaults are kept unique across the johnycsf stacks so you can run several on one host without a clash:

| Stack | Variable | Default host port |
|-------|----------|-------------------|
| `heimdall-docker` | `HTTP_PORT` | `8080` |
| `vaultwarden-docker` | `PORT` | `8081` |
| `nextcloud-office-docker` | `NEXTCLOUD_PORT` | `8082` |
| `nextcloud-office-docker` | `COLLABORA_PORT` | `9980` |
| `immich-docker` | `IMMICH_PORT` | `2283` |

Install also refuses a port another stack checked out beside this one already claims in its `.env` — even when that stack is stopped — and offers the next free port instead.

All defaults are `>= 1024` because **rootless Podman cannot publish privileged ports** (`80`, `443`). On Docker you may still set `HTTP_PORT=80` if you want.

## Container engine

During `./manage.sh` → Install you can choose **Docker** or **Podman**. The choice is saved as `CONTAINER_ENGINE` in `.env` and reused for every manage action (`update`, `backup`, `restore`, status, …) via a shared `compose` helper. Restore preserves that host choice (and host ports) even if the backup’s `.env` is older.

## Backup exports

> **Note:** After containers start, some files under `data/` may be root-owned. Install/restore automatically fixes ownership for the invoking user so host-side `rsync` backup/restore does not fail with permission errors.

Local snapshots stay as incremental hardlink trees (fast rollback). Optionally create a compressed offsite copy with `./manage.sh backup --dest ./backups --archive tar.gz|tar.xz|zip` (add `--archive-password` for zip password or age-passphrase on tar). For stronger key-based encryption use `--encrypt` (age). See repo-framework `docs/BACKUP_ENCRYPTION.md`.

## Fix greyed-out or broken library assets

If photos/videos appear greyed out, the mobile app shows upload errors, or logs mention missing thumbnails / video metadata, use the standalone repair tool (included in the clone — **not** part of `./manage.sh`):

```bash
chmod +x fix-library/fix-library.sh
./fix-library/fix-library.sh scan
./fix-library/fix-library.sh fix --apply --wait-metadata
```

See [fix-library/README.md](fix-library/README.md). Back up first: `./manage.sh backup --dest ./backups`.

## Credits

This repo packages or configures upstream software. See [CREDITS.md](CREDITS.md) for the main developers and projects this work builds on.

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

## Bug reports & contributions

If you hit an error, please [open a GitHub Issue](../../issues/new/choose) and follow [CONTRIBUTING.md](CONTRIBUTING.md). Fixes via Pull Request are welcome. GitHub Issues/PRs are the supported way to report problems—there is no private support channel.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

Sponsorship funds testing and maintenance: [github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf).
