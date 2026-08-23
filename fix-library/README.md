# Fix greyed-out library assets

Immich sometimes ends up with **greyed-out photos/videos**, **upload errors on mobile**, or **log spam** about missing thumbnails / video metadata. Common causes:

- Truncated or corrupt uploads (0-byte files, broken JPEG/MOV)
- Video metadata never extracted after a failed background job
- Items stuck in trash that were never actually uploaded

This folder is a **standalone repair tool**. It is **not** wired into `./manage.sh` — run it only when you need it.

## What it does

1. **Scans** your library for:
   - Missing or 0-byte files
   - Corrupt images (cannot be decoded)
   - Corrupt videos (`ffprobe` fails)
   - Timeline videos missing metadata but still repairable
   - Trashed items that are good vs permanently broken

2. **Fixes** (with `--apply`):
   - Restores **good** trashed assets to the library
   - Permanently removes **broken** trashed and active assets (and their files)
   - Queues Immich v3 metadata jobs (`AssetExtractMetadata`)
   - Optionally waits for metadata, then queues thumbnail jobs

## Usage

```bash
# See what is wrong (safe, no changes)
./fix-library/fix-library.sh scan

# Preview the fix plan
./fix-library/fix-library.sh fix

# Apply fixes (Immich can stay running)
./fix-library/fix-library.sh fix --apply

# Wait for metadata extraction to finish, then queue thumbnails
./fix-library/fix-library.sh fix --apply --wait-metadata

# After metadata jobs finish on their own, queue thumbnails only
./fix-library/fix-library.sh thumbnails --apply
```

Make the wrapper executable once:

```bash
chmod +x fix-library/fix-library.sh
```

## Docker Compose (this repo)

Runs `node fix-library.js` inside the `immich-server` container via your configured engine (`docker` or `podman` from `.env`).

## Kubernetes ([immich-k8s](https://github.com/johnycsf/immich-k8s))

The same scripts ship in the k8s repo. They `kubectl exec` into the `immich-server` pod (namespace `immich` by default):

```bash
IMMICH_NAMESPACE=immich ./fix-library/fix-library.sh scan
```

## Mobile upload errors

The Immich app tracks some **upload errors locally on the phone**. Cleaning the server removes orphaned/broken records so re-uploads are not blocked, but you may still need to **clear or retry failed uploads in the app** after running this tool.

## Safety

- **`scan` and `fix` without `--apply` are read-only** (except copying the script into the container).
- **`fix --apply` deletes corrupt assets permanently** — run `./manage.sh backup` first if you are unsure.
- Uses official Immich v3 job names. Older job names like `AssetMetadataExtraction` are **not** used (they are ignored by current servers).

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Greyed-out videos remain after fix | `./fix-library/fix-library.sh fix --apply --wait-metadata` |
| Metadata done but no previews | `./fix-library/fix-library.sh thumbnails --apply` |
| `immich-server is not running` | Start the stack: `./manage.sh` |
| k8s: no pod found | Check `kubectl -n immich get pods` and `IMMICH_NAMESPACE` |

See also [Immich troubleshooting](https://docs.immich.app/) and back up before destructive fixes.
