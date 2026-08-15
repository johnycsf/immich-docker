# immich-docker

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/6eb113db43e751a25bbb31fc7f828245cf261118.svg "Repobeats analytics image")

Deploy [Immich](https://immich.app/) (self-hosted photo and video backup) with Docker Compose.

Kubernetes version: [immich-k8s](https://github.com/johnycsf/immich-k8s)

Uses **Immich’s official images** from GHCR (`immich-server`, `immich-machine-learning`, Immich Postgres with VectorChord) plus **Valkey** — the Redis-compatible cache Immich ships in their [official install compose](https://docs.immich.app/install/docker-compose). No LinuxServer or unofficial Immich forks.

## What you need

- Docker with Compose plugin
- `openssl` and `curl` (used by `install.sh` / health checks)
- Enough disk for your photo library (plan ahead — libraries grow)

## Install

```bash
git clone https://github.com/johnycsf/immich-docker.git
cd immich-docker
chmod +x install.sh
./install.sh
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
