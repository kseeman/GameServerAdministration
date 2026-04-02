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

**Docker compose generation**: Templates at `games/<game>/docker/docker-compose.template.yml` are rendered into `docker-compose-<env>-<instance>.yml` at runtime using envsubst. Generated compose files are gitignored.

**Backup system**: Backups are Docker volume snapshots stored as tarballs with `.meta.json` sidecar files under `backups/<env>/<instance>/`. Emergency backups are created automatically before destructive operations into `backups/emergency/`. Backup/restore logic lives in the game plugin (`palworld_backup_data`, `palworld_restore_data`).

## Common Commands

```bash
# Server operations (all require --game, --instance, --env)
./scripts/core/server-manager.sh start --game palworld --instance main --env production --preset tournament
./scripts/core/server-manager.sh stop --game palworld --instance main --env production
./scripts/core/server-manager.sh backup --game palworld --instance main --env production
./scripts/core/server-manager.sh restore --game palworld --instance test --env staging --backup <file>.tar.gz

# Deployment
./scripts/deployment/deploy.sh --env staging --game palworld --context tournament --preset tournament.json
./scripts/deployment/deploy.sh --env staging --game palworld --context test --preset test.json --dry-run

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
