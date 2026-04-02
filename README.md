# GameServerAdministration

A Dockerized game server management platform with a plugin architecture for running multiple concurrent game server instances across staging and production environments. Built around Docker containers, preset-based configuration, automated backup/restore, and live config swapping.

Currently supports **Palworld**. Designed to be game-agnostic — adding a new game requires only a plugin script and configuration files.

## Prerequisites

- Docker and Docker Compose
- `jq` (JSON processing)
- `bash` 4.0+
- `envsubst` (part of `gettext`)

## Quick Start

```bash
# Start a Palworld server with the casual preset
./scripts/core/server-manager.sh start --game palworld --instance test --env staging --preset casual --force

# Check server status
./scripts/core/server-manager.sh status --game palworld --instance test --env staging

# Swap to tournament settings (stops, reconfigures, restarts with same world data)
./scripts/core/server-manager.sh config-swap --game palworld --instance test --env staging --preset tournament --force

# Create a backup
./scripts/core/server-manager.sh backup --game palworld --instance test --env staging --force

# Stop the server
./scripts/core/server-manager.sh stop --game palworld --instance test --env staging --force
```

## Architecture

### Project Structure

```
games/palworld/                     # All Palworld-specific files
  docker/
    docker-compose.template.yml     # Compose template (envsubst'd at runtime)
    Dockerfile                      # Custom image build (alternative to thijsvanloef)
  environments/
    production.json                 # Production: ports, instances, docker limits, passwords
    staging.json                    # Staging: same structure, different values
  presets/
    default.json                    # Base game settings (all presets inherit from this)
    casual.json                     # Relaxed settings (inherits default)
    hardcore.json                   # Maximum difficulty (inherits default)
    tournament.json                 # PvP competitive (inherits default)
    tournament-pve.json             # PvE competitive (inherits tournament)
  scripts/
    game-specific-logic.sh          # Plugin: start, stop, backup, restore, config-swap

scripts/                            # Game-agnostic orchestration
  core/
    server-manager.sh               # Universal CLI entry point
  shared/
    server-utils.sh                 # Shared utilities (validation, naming, ports, logging)
    game-plugins.sh                 # Plugin loader and function dispatch
  deployment/
    deploy.sh                       # Deploy to staging/production servers
    health-check.sh                 # Post-deployment health checks
    rollback.sh                     # Rollback to previous deployment
  automation/
    scheduled-backup.sh             # Cron-driven backup for all instances
    scheduled-config-swap.sh        # Cron-driven day-of-week preset rotation
    setup-config-swap.sh            # Install config swap cron jobs
    setup-cron.sh                   # Install backup cron jobs

systemd/
  generate-services.sh              # Generate systemd unit files from config
  templates/
    game-server@.service.template   # Systemd service template

.state/                             # Runtime: active preset tracking (gitignored)
backups/                            # Runtime: backup storage (gitignored)
```

### Plugin System

`server-manager.sh` is the universal CLI. It loads game-specific plugins from `games/<game>/scripts/game-specific-logic.sh` and delegates operations to functions named `<game>_<operation>()`.

Required plugin functions:
- `<game>_start_server` — start a container with a given preset
- `<game>_stop_server` — stop and remove the container
- `<game>_restart_server` — restart without changing config
- `<game>_health_check` — check container and service health
- `<game>_config_swap` — stop, reconfigure, and restart with a new preset
- `<game>_backup_data` — backup save data and config from the volume
- `<game>_restore_data` — restore save data and config to the volume
- `<game>_validate_preset` — validate a preset JSON file
- `<game>_get_ports` — return port assignments

### Three-Axis Server Identification

Every server operation requires three identifiers:

| Flag | Purpose | Examples |
|------|---------|----------|
| `--game` | Which game | `palworld` |
| `--instance` | Which server instance | `main`, `tournament`, `test` |
| `--env` | Which environment | `staging`, `production` |

These determine container names (`palworld-staging-test`), volume names (`palworld-vol-staging-test`), and port assignments.

### Environment Configuration

Each game has a per-environment JSON config at `games/<game>/environments/<env>.json` containing:

- **server_infrastructure** — server display name, admin/server passwords
- **network_config** — base ports and per-instance offset (e.g., offset of 10 means instance 0 gets port 8215, instance 1 gets 8225)
- **docker_config** — restart policy, memory/CPU limits
- **backup_config** — retention count and cron schedule
- **instances** — available instances with default preset, port offset, and max players

Port allocation:
- Production base ports: game=8215, query=27019, rcon=25577, restapi=9999
- Staging base ports: game=9215, query=28019, rcon=26577, restapi=10999
- Each instance adds `port_offset * port_offset_per_instance` to the base

## Server Manager CLI Reference

```
./scripts/core/server-manager.sh <operation> --game <game> --instance <instance> --env <env> [options]
```

### Operations

| Operation | Description | Required Flags |
|-----------|-------------|----------------|
| `start` | Start a game server | `--game`, `--instance`, `--env`, `--preset` |
| `stop` | Stop a game server | `--game`, `--instance`, `--env` |
| `restart` | Restart (without config change) | `--game`, `--instance`, `--env` |
| `config-swap` | Stop, reconfigure, restart with new preset | `--game`, `--instance`, `--env`, `--preset` |
| `status` | Show server status and details | `--game`, `--instance`, `--env` |
| `health` | Run health checks | `--game`, `--instance`, `--env` |
| `list` | List all running servers for a game | `--game`, `--env` |
| `backup` | Create backup of server data | `--game`, `--instance`, `--env` |
| `restore` | Restore from backup (server must be stopped) | `--game`, `--instance`, `--env`, `--backup` |
| `list-backups` | List available backups | `--game`, `--instance`, `--env` |
| `validate` | Validate game plugin | `--game`, `--env` |

### Options

| Flag | Description |
|------|-------------|
| `--preset <name>` | Preset name (without `.json` extension) |
| `--backup <file>` | Backup filename for restore |
| `--dry-run` | Validate without executing |
| `--force` | Skip safety confirmation prompts |

## Config Swap

Config swapping changes a running server's game settings while preserving world data.

### How It Works

The Palworld server reads `PalWorldSettings.ini` on startup and caches all settings in memory. Changes to the ini file while the server is running are overwritten when the server shuts down. Additionally, the server runs as a service inside the container — stopping the game process causes it to restart immediately.

The config swap flow:
1. Creates an emergency backup of the full volume
2. Stops the container (`docker compose down`)
3. Generates `PalWorldSettings.ini` from the target preset JSON
4. Injects the ini file into the Docker volume
5. Starts a new container (`docker compose up -d`) with `DISABLE_GENERATE_SETTINGS=true` so the thijsvanloef image doesn't overwrite the ini

```bash
# Switch from casual to tournament settings
./scripts/core/server-manager.sh config-swap \
  --game palworld --instance main --env production --preset tournament --force
```

Using `restart --preset <name>` also triggers a config swap (since `docker compose restart` alone doesn't apply new settings).

### Presets

Presets are JSON files in `games/<game>/presets/` that define game settings. They support single-level inheritance via `metadata.inherits`.

```json
{
  "metadata": {
    "name": "Casual",
    "inherits": "default.json"
  },
  "game_settings": {
    "Difficulty": "Easy",
    "ExpRate": 2.0,
    "DeathPenalty": "None"
  }
}
```

Keys in `game_settings` must use the exact PalWorldSettings.ini key names (e.g., `bIsPvP`, `DeathPenalty`, `DenyTechnologyList`). These are the game's native setting names, not the thijsvanloef Docker image's UPPER_SNAKE_CASE env var names.

Available presets:
| Preset | Description |
|--------|-------------|
| `default` | Base configuration, all standard rates |
| `casual` | Relaxed: 2x XP, no death penalty, faster hatching |
| `hardcore` | Maximum difficulty: reduced rates, no fast travel |
| `tournament` | Competitive PvP: player damage, guild limits, tech bans |
| `tournament-pve` | Tournament rules but with PvP disabled |

### Scheduled Config Swap

Automatically rotates presets on a day-of-week schedule. Runs daily at 8 AM, only swaps when the target preset differs from the current one.

Default tournament schedule: PvE (Mon/Tue/Fri) and PvP (Wed/Thu/Sat/Sun).

```bash
# Check what preset should be active today
./scripts/automation/scheduled-config-swap.sh \
  --game palworld --instance tournament --env production --check-only

# Install the cron job
./scripts/automation/setup-config-swap.sh --install
```

Schedule configuration lives in `config/schedule-config.json`.

## Backup and Restore

### Creating Backups

Backups capture `SaveGames/` and `Config/` from the Docker volume (not the full server installation). If the server is running, a game save is triggered via the REST API before copying.

```bash
./scripts/core/server-manager.sh backup \
  --game palworld --instance main --env production --force
```

Backups are stored at `backups/<env>/<instance>/` as `.tar.gz` files with `.meta.json` sidecars containing:
- World ID, active preset, timestamp
- Port assignments, server name, max players
- Volume and container names

### Restoring from Backup

Restore replaces the volume's `SaveGames/` and `Config/` directories with the backup contents. The server **must be stopped** before restoring.

```bash
# Stop the server
./scripts/core/server-manager.sh stop \
  --game palworld --instance main --env production --force

# Restore (searches backups/<env>/<instance>/ for the filename)
./scripts/core/server-manager.sh restore \
  --game palworld --instance main --env production \
  --backup casual_main_production_20260402_111605.tar.gz --force

# Start with desired preset
./scripts/core/server-manager.sh start \
  --game palworld --instance main --env production --preset casual --force
```

### Emergency Backups

Full volume backups created automatically before config-swap operations. Stored in `backups/emergency/` with retention of the last 3 per game+instance+env.

### Scheduled Backups

```bash
# Install cron jobs for automated backups
./scripts/automation/setup-cron.sh --install

# Run manually
./scripts/automation/scheduled-backup.sh --env production --game palworld
```

Backup schedules are configured per-environment in the game's environment config (`backup_config.backup_schedule`).

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `pr-validation.yml` | PR to `main` | shellcheck, JSON validation, bash syntax, security scan |
| `deploy-staging.yml` | Push to `develop` | Deploy to staging server via SSH |
| `deploy-production.yml` | Push to `main` | Deploy to production with rollback on failure |

Deployments package `scripts/`, `games/`, and `systemd/` into a tarball, deploy to `/opt/gameserver-admin` on the target server (owned by `root:gameserver`), and run post-deployment health checks.

## Adding a New Game

1. Create the game directory structure:
   ```
   games/<game>/
     docker/docker-compose.template.yml
     environments/production.json
     environments/staging.json
     presets/default.json
     scripts/game-specific-logic.sh
   ```

2. Implement the required plugin functions in `game-specific-logic.sh` (use `palworld` as a reference). The plugin system can generate a template:
   ```bash
   source scripts/shared/game-plugins.sh
   create_plugin_template <game>
   ```

3. Define instances, ports, and infrastructure in the environment JSON files.

4. Create preset JSON files with `game_settings` matching the game's native config key names.
