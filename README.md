# immich-docker

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/6eb113db43e751a25bbb31fc7f828245cf261118.svg "Repobeats analytics image")

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

Deploy [Immich](https://immich.app/) (self-hosted photo and video backup) with Docker Compose.

Kubernetes version: [immich-k8s](https://github.com/johnycsf/immich-k8s)

Uses **Immich’s official images** from GHCR (`immich-server`, `immich-machine-learning`, Immich Postgres with VectorChord) plus **Valkey** — the Redis-compatible cache Immich ships in their [official install compose](https://docs.immich.app/install/docker-compose). No LinuxServer or unofficial Immich forks.

**One-command Immich for homelab beginners** — official images, interactive install, safe updates & backups.

> **Choose your path:** **Docker Compose (this repo)** · [Kubernetes](https://github.com/johnycsf/immich-k8s)

## Who this is for

**Good fit:** homelab beginners who want Immich with official images and a guided install/update/backup flow.

**Not for:** production multi-tenant photo hosting, or forks/unofficial Immich images — this stack sticks to Immich’s official GHCR images.

## Why this repo (not just another compose file)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools
- Safe **`./manage.sh update`** with automatic pre-update backup
- Incremental hardlink **`./manage.sh backup`** + restore
- **Official upstream images only**

## Support this work

If this stack saved you setup time, please consider sponsoring — it funds:

- Keeping install/update/backup scripts working across common Linux distros
- Testing safe upgrades against **official** upstream images
- Building more beginner-friendly stacks that share the same `./manage.sh` UX

[![Sponsor johnycsf](https://img.shields.io/badge/GitHub%20Sponsors-Donate-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

👉 **[github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf)**

## What you need

- A Linux host (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) or macOS with Homebrew
- `sudo` so `./manage.sh` can install missing tools (Docker, curl, openssl, rsync, …)
- Enough disk for your data

`./manage.sh` is interactive (colors + step progress), detects your OS, and installs host dependencies automatically.

## Install

```bash
git clone https://github.com/johnycsf/immich-docker.git
cd immich-docker
chmod +x manage.sh
./manage.sh          # interactive control center
# or: ./manage.sh
```

Open the URL the script prints, create your admin account, then use the Immich mobile apps.

Liked the install? Star the repo or [sponsor johnycsf](https://github.com/sponsors/johnycsf) so more stacks stay maintained.

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

Roll back / disaster restore:

```bash
./manage.sh backup --restore --from ./backups
# or from an external copy:
./manage.sh backup --restore --from /mnt/usb/immich-backups
```

## Disaster recovery (full backup / restore)

```bash
# Prefer an external drive or NAS (libraries are large; hardlinks need one filesystem)
./manage.sh backup --dest /mnt/usb/immich-docker-backups --keep 3

# Optional: also snapshot ML model cache
./manage.sh backup --dest /mnt/usb/immich-docker-backups --keep 3 --include-model-cache

# On a new machine after ./manage.sh (or with compose present):
./manage.sh backup --restore --from /mnt/usb/immich-docker-backups
```

Each snapshot includes `SHA256SUMS` / `snapshot_sha256` for dumps and config. The photo library uses a fast size+path fingerprint (full per-file hashing of hundreds of GB would thrash the disk). Restore **warns** if integrity looks wrong but does not abort.

**Database safety:** Postgres is backed up with a verified logical `pg_dump` — the live database files are never rsync’d while running.

## Uninstall

```bash
docker compose down
# optional: delete local data (DESTROYS your library)
rm -rf data
```

## Notes

- Follow Immich release notes when jumping major versions.
- Hardware acceleration for ML/transcoding is optional; see Immich docs and the commented `hwaccel` examples in upstream compose if you need them later.

## Credits

This repo packages or configures upstream software. See [CREDITS.md](CREDITS.md) for the main developers and projects this work builds on.

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

## Bug reports & contributions

If you hit an error, please [open a GitHub Issue](../../issues/new/choose) and follow [CONTRIBUTING.md](CONTRIBUTING.md). Fixes via Pull Request are welcome. GitHub Issues/PRs are the supported way to report problems—there is no private support channel.

## Interactive control center

`./manage.sh` opens a simple **↑/↓ menu** with a `>` cursor (j/k and Enter also work). No extra packages required.

## Host ports

During `./manage.sh` (or Manage → Install / reconfigure), the script checks whether default host ports are free, lets you keep the defaults or choose different ports, and saves them in `.env`. Re-running install keeps your current ports unless you change them.

Non-interactive: set the port variables in `.env` (or the environment) and use `SKIP_PORT_PROMPTS=1`.

## Container engine

During `./manage.sh` → Install you can choose **Docker** or **Podman**. The choice is saved as `CONTAINER_ENGINE` in `.env`. All manage actions (`update`, `backup`, `restore`, …) use that engine via a shared `compose` helper.

## Backup exports

> **Note:** After containers start, some files under `data/` may be root-owned. Install/restore automatically fixes ownership for the invoking user so host-side `rsync` backup/restore does not fail with permission errors.

Local snapshots stay as incremental hardlink trees (fast rollback). Optionally create a compressed offsite copy with `./manage.sh backup --dest ./backups --archive tar.gz|tar.xz|zip` (add `--archive-password` for zip password or age-passphrase on tar). For stronger key-based encryption use `--encrypt` (age). See repo-framework `docs/BACKUP_ENCRYPTION.md`.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.
