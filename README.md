# immich-docker

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/6eb113db43e751a25bbb31fc7f828245cf261118.svg "Repobeats analytics image")


[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

Deploy [Immich](https://immich.app/) (self-hosted photo and video backup) with Docker Compose.

Kubernetes version: [immich-k8s](https://github.com/johnycsf/immich-k8s)

Uses **Immich’s official images** from GHCR (`immich-server`, `immich-machine-learning`, Immich Postgres with VectorChord) plus **Valkey** — the Redis-compatible cache Immich ships in their [official install compose](https://docs.immich.app/install/docker-compose). No LinuxServer or unofficial Immich forks.


## Why this repo (not just another compose file)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools
- Safe **`./update.sh`** with automatic pre-update backup
- Incremental hardlink **`./backup.sh`** + restore
- **Official upstream images only**

## What you need

- A Linux host (Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine) or macOS with Homebrew
- `sudo` so `./install.sh` can install missing tools (Docker, curl, openssl, rsync, …)
- Enough disk for your data

`./install.sh` is interactive (colors + step progress), detects your OS, and installs host dependencies automatically.

## Install

```bash
git clone https://github.com/johnycsf/immich-docker.git
cd immich-docker
chmod +x manage.sh install.sh
./manage.sh          # interactive control center
# or: ./install.sh
```

Open the URL the script prints, create your admin account, then use the Immich mobile apps.

## Customize

Edit `.env` (created from `.env.example`):

| Variable | Purpose |
|----------|---------|
| `IMMICH_PORT` | Host port (default `2283`) |
| `IMMICH_VERSION` | Immich tag (default `v3`; pin e.g. `v3.1.0` if you prefer) |
| `TZ` | Timezone |
| `UPLOAD_LOCATION` | Photo library on disk (default `./data/library`) |
| `DB_DATA_LOCATION` | Postgres files (default `./data/postgres`) |
| `DB_PASSWORD` | Database password (auto-generated; alphanumeric only) |

## Update

```bash
chmod +x update.sh
./update.sh
```

Before updating, the script runs `./backup.sh` into `./backups` (Postgres dump + incremental library hardlinks). Afterward it asks whether to keep that snapshot and how many copies to retain.

Roll back / disaster restore:

```bash
./backup.sh --restore --from ./backups
# or from an external copy:
./backup.sh --restore --from /mnt/usb/immich-backups
```

## Disaster recovery (full backup / restore)

```bash
chmod +x backup.sh

# Prefer an external drive or NAS (libraries are large; hardlinks need one filesystem)
./backup.sh --dest /mnt/usb/immich-docker-backups --keep 3

# Optional: also snapshot ML model cache
./backup.sh --dest /mnt/usb/immich-docker-backups --keep 3 --include-model-cache

# On a new machine after ./install.sh (or with compose present):
./backup.sh --restore --from /mnt/usb/immich-docker-backups
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

## Support this work

If these homelab tools save you time, please consider sponsoring:

[![Sponsor johnycsf](https://img.shields.io/badge/GitHub%20Sponsors-Donate-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

👉 **[github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf)** — tips and monthly support keep these beginner-friendly stacks maintained.

