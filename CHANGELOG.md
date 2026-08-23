## Unreleased

- Add standalone `fix-library/` tool to scan and repair greyed-out assets, corrupt uploads, and missing video metadata (not part of `manage.sh`).

- Pin `IMMICH_PORT: 3003` in `immich-machine-learning` compose environment to prevent ML worker from inheriting customized server ports and breaking machine learning endpoints.

- Set Compose `restart: always` and enable `podman-restart.service` so rootless Podman brings containers back after a host reboot.

- Fix root-owned data dirs after compose/restore so host rsync backup/restore works for all users.

- Install can choose **Docker** or **Podman** (`CONTAINER_ENGINE` in `.env`).

- Manage menu includes **Restore** (backup root, snapshot, or archive).

- Single entrypoint: `./manage.sh` (install/update/backup helpers moved under `scripts/`).

- Native ↑/↓ `>` menus in `./manage.sh` (replaced gum/whiptail chooser).

- Optional compressed backup exports (`--archive tar.gz|tar.xz|zip`) with simple password protection; age remains available for strong crypto.

- Install prompts for host ports with conflict detection (keep defaults or choose custom).

- Optional age-encrypted backup exports (`--encrypt`) for offsite disaster recovery.

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) where tagged releases exist.

## [Unreleased]
- Open the host firewall port on **ufw** hosts (Ubuntu/Debian/Mint) during install, not just firewalld. Previously the install finished and the app answered on localhost while every other machine on the LAN was blocked, which looks like a failed install.
- Fix rootless Podman host-port remap writing the notice text into `.env` instead of the port number.
- Fix `ensure_host_owned_dir` silently skipping ownership repair when nested files were wrong (`find|head` SIGPIPE under `pipefail`).
- Shell scripts are now pure ASCII; displayed glyphs come from `$'\uXXXX'` constants so editors cannot corrupt the UI. Terminal output is unchanged.
- Fix `compose_service_running` matching containers by the compose `working_dir` label, so backups work when the repo is cloned under a different directory name.
- Skip `--wait`/`--wait-timeout` on podman-compose during update and restore (unsupported; the update aborted before the API check).
- Refuse a host port another stack beside this one already claims in its `.env` (catches installed-but-stopped stacks) and offer the next free port.
- Rootless Podman: remap privileged host ports (e.g. 80) to unprivileged defaults (8080) so install can bind.
- Document batching related fixes into one `testing` → `main` PR (avoid one-PR-per-microfix).
- Fix backup dump verification under `pipefail` (gzip|head SIGPIPE looked like a bad dump).
- Fix Podman backup/status: detect running services without `compose ps -q SERVICE` (unsupported by podman-compose).
- Restore preserves host `UPLOAD_LOCATION` / `DB_DATA_LOCATION` and syncs the library to that path (fixes empty `./volume/library` after restoring a snapshot whose `.env` used Immich's volume layout).
- Backup `--dest` always nests under `<dest>/<STACK_ID>/` so multiple services share one disk without mixing.
- Fix restore abort: empty optional ports tripped `set -e` in save_host_install_env.
- Open chosen host ports in firewalld during install (rootless Podman needs this for LAN access).
- Show live progress for compose pull/build (`ui_run --stream`) so long image downloads do not look frozen.
- Fix features blurb: backticks around CONTAINER_ENGINE ran it as a shell command.
- Control-center banner uses remembered Docker/Podman engine label.
- UI polish: install/doctor/uninstall banners reflect Docker vs Podman from `CONTAINER_ENGINE`.
- Remember `CONTAINER_ENGINE` from `.env` for all manage actions; preserve it (and host ports) across restore; stop hard-requiring `docker` when Podman is selected.
- Podman: prefer `podman-compose` over `podman compose`/docker-compose plugin; silence provider banner.
- Clarify that `main` stays the GitHub default; log bugs as Issues during testing.
- Document `testing` → `main` PR workflow (verify first, include CHANGELOG).
- Install: do not chown `data/postgres`/`data/redis` after start (breaks container UIDs under Podman).
- Podman: drop compose `healthcheck: disable: false` (Podman requires an explicit test command).
- Ensure rootless Podman API socket (`podman.socket` + linger) before `podman compose`.
- Fix `compose_engine` Docker path (was recursively calling itself instead of `docker compose`).

### Added

- Interactive `./manage.sh` control center (where applicable)
- Soft pastel terminal UI for install/manage scripts
- `DISCLAIMER.md`, `CREDITS.md`, `CONTRIBUTING.md`, Sponsors funding links
- GitHub Issue bug report template

### Changed

- Standardized beginner-friendly install, update, and backup UX

### Fixed

- Custom `IMMICH_PORT` values now map host and container to the same port (Immich v3 listens on `IMMICH_PORT`; a host-only remap previously broke the API wait)
- Compose project renamed to `immich-docker` and fixed `container_name`s removed so this stack can run beside another Immich install

<!--
## [1.0.0] - YYYY-MM-DD
### Added
- Initial public release
-->
