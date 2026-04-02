# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dockerized game server management platform with a plugin architecture. Currently supports Palworld, designed to be game-agnostic. Manages multiple concurrent server instances across staging and production environments with Docker containers, preset-based configuration, and automated backup/restore.

## Architecture

**Plugin system**: `scripts/core/server-manager.sh` is the universal entry point. It delegates to game-specific plugins at `games/<game>/scripts/game-specific-logic.sh` via `scripts/shared/game-plugins.sh`. Plugin functions follow the naming convention `<game>_<operation>()` (e.g., `palworld_start_server`).

**Shared utilities**: `scripts/shared/server-utils.sh` provides environment validation, port assignment, container helpers, and logging. The key function `get_game_env_config()` resolves the config path for any game+environment combination. All core and game scripts source this.

**Game directory structure**: All game-specific files live under `games/<game>/`:
- `environments/production.json`, `environments/staging.json` — consolidated per-environment config (ports, instances, docker limits, backup settings, server infrastructure)
- `presets/<name>.json` — game settings presets (e.g., tournament, casual, hardcore)
- `docker/` — Dockerfile and docker-compose.template.yml
- `scripts/game-specific-logic.sh` — plugin implementing the required function interface

**Environment/instance model**: Servers are identified by three axes: `--game`, `--instance`, and `--env`. Each game's environment config at `games/<game>/environments/<env>.json` defines available instances, base ports, port offsets, docker resource limits, and backup retention.

## Config Swap System

Config swapping changes a running server's game settings (e.g., switching from casual to tournament mode) while preserving world data.

**How it works**: The Palworld server reads `PalWorldSettings.ini` on startup and caches settings in memory. You cannot change settings while the server is running — changes are overwritten on shutdown. The flow is:
1. Stop the container (`docker compose down`)
2. Generate `PalWorldSettings.ini` from the preset JSON and inject it into the Docker volume
3. Start a new container (`docker compose up -d`) with `DISABLE_GENERATE_SETTINGS=true` so the thijsvanloef image doesn't overwrite the ini

**Preset inheritance**: Presets can inherit from a parent via `metadata.inherits`. `palworld_resolve_preset()` merges parent `game_settings` with child overrides using jq. For example, `casual.json` inherits from `default.json` and only overrides the settings it changes.

**Preset key names**: Keys in `game_settings` must match the exact PalWorldSettings.ini key names (e.g., `bIsPvP`, `DeathPenalty`, `DenyTechnologyList`). These are NOT the thijsvanloef image's UPPER_SNAKE_CASE env var names — we bypass the image's settings generation entirely.

**State tracking**: After a successful start or config-swap, the active preset name is written to `.state/palworld-<env>-<instance>.preset`. This is read by `scheduled-config-swap.sh` to detect the current preset and by `palworld_backup_data()` to tag backup metadata.

## Backup and Restore

**Regular backups** (`palworld_backup_data`): Game-specific, only captures `SaveGames/` and `Config/` from the volume (not the full server installation). Triggers a game save via REST API before copying if the server is running. Produces a `.tar.gz` with a `.meta.json` sidecar containing world ID, active preset, ports, and timestamps.

**Emergency backups** (`create_emergency_backup` in `server-utils.sh`): Full volume copy, game-agnostic. Created automatically before config-swap operations. Retains the last 3 per game+instance+env combination.

**Restore** (`palworld_restore_data`): Nukes existing `SaveGames/` and `Config/` in the volume and replaces them wholesale from the backup. The backup's `GameUserSettings.ini` contains the correct `DedicatedServerName` matching the world folder in `SaveGames/0/<worldId>/`. Container must be stopped before restoring.

## Common Commands

```bash
# Server operations (all require --game, --instance, --env)
./scripts/core/server-manager.sh start --game palworld --instance main --env production --preset tournament
./scripts/core/server-manager.sh stop --game palworld --instance main --env production
./scripts/core/server-manager.sh status --game palworld --instance main --env production
./scripts/core/server-manager.sh config-swap --game palworld --instance main --env production --preset casual --force
./scripts/core/server-manager.sh backup --game palworld --instance main --env production --force
./scripts/core/server-manager.sh restore --game palworld --instance test --env staging --backup <file>.tar.gz --force
./scripts/core/server-manager.sh list-backups --game palworld --instance main --env production

# Scheduled config swap (cron-driven day-of-week preset rotation)
./scripts/automation/scheduled-config-swap.sh --game palworld --instance tournament --env production --check-only
./scripts/automation/scheduled-config-swap.sh --game palworld --instance tournament --env production --dry-run

# Validation (used by PR CI)
shellcheck scripts/**/*.sh
bash -n scripts/core/server-manager.sh
find games/ -name "*.json" -exec jq empty {} \;
```

## CI/CD

- **PR validation** (`pr-validation.yml`): Runs shellcheck, JSON validation, and bash syntax checks on PRs to `main`.
- **Staging deploy** (`deploy-staging.yml`): Triggers on push to `develop` branch. SSHs to staging server, deploys to `/opt/gameserver-admin`.
- **Production deploy** (`deploy-production.yml`): Triggers on push to `main`.

Deployments install to `/opt/gameserver-admin` on the target server, owned by `root:gameserver`.

## Key Conventions

- Environments are strictly `staging` or `production` (validated by `validate_environment()`).
- Naming patterns: containers are `{game}-{env}-{instance}`, volumes are `{game}-vol-{env}-{instance}`.
- Port allocation: base ports and per-instance offsets are defined in `games/<game>/environments/<env>.json` under `network_config`.
- All shell scripts use `SCRIPT_DIR`/`REPO_ROOT` pattern for path resolution relative to the repo root.
- `jq` is a required dependency for config operations.
- Docker compose files are generated at runtime and gitignored. The template lives in `games/<game>/docker/`.
- Active preset state is tracked in `.state/` (gitignored).
