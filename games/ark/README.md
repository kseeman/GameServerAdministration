# ARK Survival Ascended

Game-specific design and operations guide for the ARK SA plugin. For project-wide concepts (the universal CLI, environment/instance model, deployment), see the top-level [`README.md`](../../README.md) and [`CLAUDE.md`](../../CLAUDE.md).

## Overview

- **Image**: `acekorneya/asa_server:2_1_latest` (a.k.a. POK-manager)
- **Plugin**: `games/ark/scripts/game-specific-logic.sh`
- **Config files**: ARK uses **two** ini files — `GameUserSettings.ini` and `Game.ini`. Both live in `ShooterGame/Saved/Config/WindowsServer/` inside the volume.
- **Health/admin**: RCON only (no REST API). `rcon-cli` is shipped in the image; the plugin invokes it via `docker exec`.

Notable features wired into this plugin:
- **Hot config swap** for a curated set of settings — no restart needed.
- **Cross-instance clustering** within a single environment — players can transfer characters/dinos/items between maps in the same cluster.

## Architecture

### Containers

Each ARK instance runs **two** containers, started together via a generated compose project:

| Container | Image | Purpose |
|-----------|-------|---------|
| `ark-{env}-{instance}` | `acekorneya/asa_server` | Game server |
| `ark-{env}-{instance}-config` | `nginx:alpine` | Sidecar that serves a dynamic config ini over HTTP for ARK's `-CustomDynamicConfigUrl` mechanism |

The game server passes `-CustomDynamicConfigUrl=http://ark-config:80/GameUserSettings.ini` via `CUSTOM_SERVER_ARGS`. ARK polls this URL periodically and applies any whitelisted settings without restarting (see [Config swap](#config-swap)).

### Volumes

Five volumes per environment + per instance:

| Volume | Pattern | Scope | Contents |
|--------|---------|-------|----------|
| Server files | `ark-server-files-{env}` | Shared per env | Game install (~50 GB) — re-downloaded by SteamCMD on boot if missing |
| Save data | `ark-vol-{env}-{instance}` | Per instance | `ShooterGame/Saved/` — world, configs, logs |
| Dynamic config | `ark-dynconfig-{env}-{instance}` | Per instance | A single `GameUserSettings.ini` with hot-swappable settings, served by the nginx sidecar |
| Cluster | `ark-cluster-{env}` | **Shared per env** | Uploaded survivors, dinos, items in transit between cluster nodes |
| (volume mount) | `Saved/clusters/` | — | The cluster volume is mounted *inside* the save volume's path, shadowing it |

The cluster volume mount nesting matters: `ark_saved_data` mounts at `Saved/`, then `ark_cluster_data` mounts at `Saved/clusters/`. Docker's deeper mount takes precedence — every instance with the same `cluster_id` reads/writes the same shared `clusters/` directory.

### Plugin function map

All ARK functions are exported from `game-specific-logic.sh`:

- `ark_start_server`, `ark_stop_server`, `ark_restart_server` — lifecycle
- `ark_health_check` — container running + game port listening + RCON `ListPlayers`
- `ark_config_swap` — hot path first, cold fallback
- `ark_backup_data`, `ark_restore_data`
- `ark_resolve_preset`, `ark_validate_preset` — JSON preset handling
- `ark_generate_game_user_settings_ini`, `ark_generate_game_ini`, `ark_inject_settings` — write static ini files into the save volume before container start
- `ark_generate_dynamic_config_ini`, `ark_write_dynamic_config` — write the hot-swap ini into the nginx sidecar volume
- `ark_is_hot_swappable` — diff two presets, return 0 if every changed key is in the allowlist
- `ark_rcon_command` — wrapper around `docker exec ... rcon-cli`
- `ark_save_active_preset`, `ark_get_active_preset` — `.state/ark-{env}-{instance}.preset`

## Configuration

### Environment JSON

`games/ark/environments/{staging,production}.json` defines:

- **`game.docker_image`**, **`game.update_on_boot`**
- **`server_infrastructure.base_server_name`** — used as session name prefix; per-instance suffix is `instances.<name>.description`
- **`network_config.base_ports`** — `game_port`, `query_port`, `rcon_port`. ARK has no REST API, so `restapi_port` is `0`.
- **`network_config.port_offset_per_instance`** — multiplied by each instance's `port_offset` to derive its actual ports
- **`docker_config`** — `restart_policy`, `memory_limit`, `cpu_limit`
- **`backup_config`** — `backup_retention`, `backup_schedule` (cron), `backup_location`
- **`cluster_config`** — `cluster_id` (shared across instances in the cluster), `cluster_volume` (Docker volume name); set `cluster_id` to empty string to disable clustering for that env
- **`instances.<name>`** — `description`, `map`, `default_preset`, `port_offset`, `max_players`, `mod_ids`, `passive_mods`

Default ports as configured today:

| Env | Game | Query | RCON |
|-----|-----:|------:|-----:|
| Production | 7790 | 27030 | 27050 |
| Staging | 17777 | 37015 | 37020 |

Instances configured today:

- Production: `island` (TheIsland_WP, offset 0), `aberration` (Aberration_WP, offset 1)
- Staging: `test` (TheIsland_WP, offset 0), `aberration` (Aberration_WP, offset 1)

### Secrets

Two passwords required per environment, loaded from a gitignored `.env` at the repo root:

```
ARK_PRODUCTION_ADMIN_PASSWORD=...   # RCON / in-game admin
ARK_PRODUCTION_BASE_PASSWORD=...    # Server join password (empty string = open server)
ARK_STAGING_ADMIN_PASSWORD=...
ARK_STAGING_BASE_PASSWORD=...
```

`get_secret` in `scripts/shared/server-utils.sh` is **strict on missing**, **lenient on empty** — an unset variable aborts the start with a clear error; an explicitly empty value is treated as "no password."

### Presets

Presets are JSON files in `games/ark/presets/` with single-level inheritance from `default.json`. Structure:

```json
{
  "metadata": {
    "name": "Boosted",
    "inherits": "default.json"
  },
  "game_settings": {
    "GameUserSettings": {
      "ServerSettings": { "XPMultiplier": 5.0, ... },
      "SessionSettings": { "SessionName": "..." },
      "MessageOfTheDay": { "Message": "...", "Duration": 20 }
    },
    "Game": {
      "/Script/ShooterGame.ShooterGameMode": { "TamingSpeedMultiplier": 5.0, ... }
    }
  }
}
```

Two top-level sections — `GameUserSettings` writes to `GameUserSettings.ini`, `Game` writes to `Game.ini`. Section names under each (e.g. `ServerSettings`, `/Script/ShooterGame.ShooterGameMode`) become `[Section]` headers in the resulting ini.

JSON booleans (`true`/`false`) are auto-capitalized to `True`/`False` for ARK ini compatibility. Server infrastructure settings (`SessionName`, `ServerAdminPassword`, `ServerPassword`, `MaxPlayers`, `RCONPort`, `RCONEnabled`) are **injected at generation time** from the env JSON and skipped from preset overrides — don't set them in presets.

Preset library:

| Preset | Description |
|--------|-------------|
| `default` | Official rates, transfers enabled, PvP allowed |
| `boosted` | 5× XP/taming/harvesting, faster breeding |
| `boosted-pve` | Boosted rates with PvP disabled |

## Setup

### Prerequisites

- Docker + Docker Compose (verify with `docker compose version`)
- `jq`, `bash` 4+, `envsubst` (gettext)
- ~60 GB disk per environment for the shared server-files volume (game install + updates)
- Inbound UDP for game/query ports, TCP for RCON (firewall as needed; do not expose RCON publicly)

### First-time start (staging)

```bash
# 1. Set passwords (.env at repo root)
echo 'ARK_STAGING_ADMIN_PASSWORD=changeme' >> .env
echo 'ARK_STAGING_BASE_PASSWORD=' >> .env   # open server

# 2. Start
./scripts/core/server-manager.sh start \
  --game ark --instance test --env staging --preset default

# 3. Watch the boot (SteamCMD install can take 10–20 min on first run)
docker logs -f ark-staging-test
```

Expected sequence in the logs:
1. Image pull (first time only)
2. SteamCMD install/update (first time only)
3. Volume seeding (server files)
4. ini files injected by the plugin
5. Server launches; RCON becomes responsive once map loads

### Adding a new instance

Edit the env JSON to add an instance under `instances`:

```json
"aberration": {
  "description": "Aberration",
  "map": "Aberration_WP",
  "default_preset": "default",
  "port_offset": 1,
  "max_players": 30,
  "mod_ids": "",
  "passive_mods": ""
}
```

Then start it:

```bash
./scripts/core/server-manager.sh start --game ark --instance aberration --env staging --preset default
```

If `cluster_config.cluster_id` is set, this instance auto-joins that cluster. The shared cluster volume is created on first start of any instance in the env.

## Server lifecycle

```bash
# Start (preset is required)
./scripts/core/server-manager.sh start --game ark --instance island --env production --preset default

# Stop (saves world via RCON before shutdown)
./scripts/core/server-manager.sh stop --game ark --instance island --env production

# Restart — if not running, falls back to start with the last active preset
./scripts/core/server-manager.sh restart --game ark --instance island --env production

# Status / health
./scripts/core/server-manager.sh status --game ark --instance island --env production
./scripts/core/server-manager.sh health --game ark --instance island --env production
```

### RCON

`ark_rcon_command` execs into the container and runs `rcon-cli` against `127.0.0.1:<rcon_port>`. Use it for ad-hoc commands:

```bash
# From a shell that's sourced the plugin, or via docker exec directly:
docker exec ark-production-island rcon-cli -a 127.0.0.1:27050 -p "$ADMIN_PW" 'ListPlayers'
docker exec ark-production-island rcon-cli -a 127.0.0.1:27050 -p "$ADMIN_PW" 'SaveWorld'
docker exec ark-production-island rcon-cli -a 127.0.0.1:27050 -p "$ADMIN_PW" 'Broadcast Server restart in 10 minutes'
```

## Config swap

Goal: change game settings on a running server without losing world state. Two paths:

### Hot swap (no restart)

`ark_is_hot_swappable` compares the active preset and the requested preset; if **every** changed key is in `ARK_HOT_SWAPPABLE_SETTINGS` (defined at the top of the plugin), the swap goes through the hot path:

1. Generate a stripped-down `GameUserSettings.ini` containing only the hot-swappable keys
2. Write it into the dynamic-config volume (served by the nginx sidecar)
3. RCON `ForceUpdateDynamicConfig` — server re-reads the URL, applies new values

Hot-swappable allowlist covers rate multipliers (XP, taming, harvest, drain, recovery, damage, breeding, crops, hexagons), some caps (`MaxPersonalTamedDinos`, `MaxTamedDinos`, `AutoSavePeriodMinutes`), and time scales. Anything else → cold swap.

### Cold swap (stop + restart)

Triggered when:
- The server is stopped, OR
- Any changed key is outside the allowlist (e.g. PvP toggle, structure decay, transfer flags)

Flow:
1. Pre-swap backup (named `pre-swap_<preset>_<timestamp>`)
2. `ark_stop_server` (SaveWorld via RCON, then compose down)
3. `ark_start_server` with the new preset — regenerates both ini files, restarts container

Both paths update `.state/ark-{env}-{instance}.preset` so the next backup and the scheduled config-swap script know what's active.

```bash
./scripts/core/server-manager.sh config-swap \
  --game ark --instance island --env production --preset boosted-pve --force
```

## Clustering

Instances in the same env with the same `cluster_id` form a cluster. Players can upload survivors/dinos/items on one map and download on another via the in-game Obelisk / Tribute Terminal interface.

### How it's wired

- `cluster_config.cluster_id` is passed as the `CLUSTER_ID` env var to the container.
- The image's `launch_ASA.sh` checks `if [ -n "$CLUSTER_ID" ]` and appends `-clusterid=$CLUSTER_ID` to the launch command. Empty value disables clustering at the server level.
- The shared `ark-cluster-{env}` Docker volume is mounted at the default ARK cluster path (`/home/pok/arkserver/ShooterGame/Saved/clusters`), shadowing any per-instance contents at that subpath.
- Transfer flags (`noTributeDownloads`, `Prevent{Upload,Download}{Survivors,Items,Dinos}`, `CrossARKAllowForeignDinoDownloads`) are baked into `default.json` so all presets inherit them.

### Disabling clustering for an environment

Set `cluster_config.cluster_id` to `""` in the env JSON. The cluster volume still gets created and mounted (harmless — empty), but the server won't pass `-clusterid=` and won't read/write transfer files.

### Isolating clusters

Production uses `cluster_id: "vauldamir-production"`, staging uses `"vauldamir-staging"`. Even though both use the same Docker host, different IDs prevent staging characters from transferring into production.

### Caveats

- **Map-restricted dinos** (Wyverns, Rock Drakes, Magmasaurs, etc.) require `CrossARKAllowForeignDinoDownloads=true` to be downloadable on maps where they don't natively spawn — already set in `default.json`.
- **Cluster files are backed up separately** from per-instance backups (per-env, on the same cron) — see [Cluster volume backup](#cluster-volume-backup).
- **Adding a new instance** to an existing live cluster is non-disruptive: existing instances keep running, the new one's first start mounts the same cluster volume.

## Backup & restore

### What's captured

`ark_backup_data` tars the entire save volume contents (`ShooterGame/Saved/`) — that's `SavedArks/`, `Config/`, `Logs/`, and any other files ARK writes there. Output: `<preset>_<instance>_<env>_<timestamp>.tar.gz` plus a `.meta.json` sidecar with active preset, ports, server name, map.

If the server is running, `SaveWorld` is sent via RCON before tarring (5-second wait for the save to complete).

### What's NOT captured

- **Server files volume** (`ark-server-files-{env}`) — the game install. Re-downloaded automatically on next start.
- **Dynamic config volume** (`ark-dynconfig-{env}-{instance}`) — regenerated from the active preset on every start.

### Cluster volume backup

The shared `ark-cluster-{env}` volume (uploaded survivors/dinos/items in transit) is captured separately from per-instance backups since it's shared across all instances in the env.

- **Cadence**: piggybacks on the existing scheduled backup cron — no second cron job. After per-instance backups run, the orchestrator (`scripts/automation/scheduled-backup.sh`) calls `ark_backup_cluster` once per env that had at least one successful instance backup.
- **Location**: `backups/{env}/_cluster/cluster_{env}_{timestamp}.tar.gz` plus a `.meta.json` sidecar containing env, cluster_id, configured instances, and timestamp.
- **Retention**: configured separately from instance backups via `cluster_backup_config.retention` in the env JSON. Defaults: 96 in production (≈8 days at 2h cadence), 24 in staging (≈4 days at 4h cadence). Cluster files are small (KB to a few MB), so generous retention is cheap.
- **Skipped when**: clustering is disabled (`cluster_id` is empty), the cluster volume doesn't exist yet, or the volume is empty (no transfers have happened).

### Cluster restore

Cluster restore is its own ad-hoc wrapper script — it's rare, env-scoped (no `--instance`), and deliberately interactive:

```bash
# List available cluster backups
./scripts/automation/ark-cluster-restore.sh --env production --list

# Restore (interactive — prompts for "restore" to confirm)
./scripts/automation/ark-cluster-restore.sh \
  --env production \
  --backup cluster_production_20260509_120000.tar.gz

# Or non-interactive
./scripts/automation/ark-cluster-restore.sh \
  --env production \
  --backup cluster_production_20260509_120000.tar.gz \
  --force
```

**Hard requirement**: every ARK instance in the env must be stopped first. The script enumerates `instances.<name>` from the env JSON and refuses to run if any matching container is alive — wiping a live-mounted volume would corrupt cluster state across all running nodes.

```bash
# Typical flow on the production host
for inst in island aberration; do
  ./scripts/core/server-manager.sh stop --game ark --instance "$inst" --env production
done

./scripts/automation/ark-cluster-restore.sh --env production \
  --backup cluster_production_20260509_120000.tar.gz --force

for inst in island aberration; do
  ./scripts/core/server-manager.sh start --game ark --instance "$inst" --env production --preset default
done
```

The restore wipes the cluster volume and replaces its contents from the tarball. Per-instance save volumes are untouched. Player characters/items uploaded between the backup timestamp and the restore moment are lost.

### Restoring

The container must be stopped first. `ark_restore_data` wipes the save volume and replaces it from the tarball:

```bash
./scripts/core/server-manager.sh stop --game ark --instance island --env production
./scripts/core/server-manager.sh restore --game ark --instance island --env production \
  --backup default_island_production_20260426_080000.tar.gz --force
./scripts/core/server-manager.sh start --game ark --instance island --env production --preset default
```

Or pass `--backup` directly to `start` after stopping (single-shot — restore happens before container boot).

The cluster volume is **not** touched by restore. Player uploads from before/after the rollback target are preserved.

### Production schedule

- Hourly cadence: every 2 hours (`0 */2 * * *`)
- Retention: 48 backups (~4 days of history)
- Location: `backups/production/<instance>/`

Configure via `backup_config` in `games/ark/environments/production.json`.

## Common operations

```bash
# List backups for an instance
./scripts/core/server-manager.sh list-backups --game ark --instance island --env production

# Validate plugin + preset JSON
./scripts/core/server-manager.sh validate --game ark --env production

# Live RCON broadcast
docker exec ark-production-island rcon-cli -a 127.0.0.1:27050 -p "$ADMIN_PW" \
  'Broadcast Maintenance in 5 minutes — please log out'

# Check what's hot-swappable between two presets (returns 0 if hot, 1 if cold needed)
source games/ark/scripts/game-specific-logic.sh
ark_is_hot_swappable games/ark/presets/default.json games/ark/presets/boosted.json
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Container starts but RCON unresponsive for 5–15 min | First-time SteamCMD install | Tail `docker logs -f`; wait for "Setting breakpad minidump..." then "Server has completed startup" |
| `Required secret not set: $ARK_STAGING_ADMIN_PASSWORD` on start | `.env` missing or var unset | Add to `~/GameServerAdministration/.env` on the server |
| Cluster transfers silently fail (no error, no items appear) | Different `cluster_id` between nodes, OR `Prevent*` flags in active preset | Verify `cluster_config.cluster_id` matches across instances; `grep -E 'Prevent\|noTribute' .../GameUserSettings.ini` should all be `False` |
| Port already in use | Another instance with same `port_offset`, or stale container | `docker ps -a | grep ark`; check env JSON for offset collisions |
| Hot swap fails, falls back to cold | Changed key not in `ARK_HOT_SWAPPABLE_SETTINGS` allowlist | Expected — some settings just need a restart |
| Save volume restore wipes mods state | Restore is a full wipe of `Saved/`; mods come from server-files volume + env JSON `mod_ids` | Confirm `mod_ids` in env JSON matches expectations; restart re-applies |
| Volume permissions errors after manual `docker cp` | ARK runs as UID 7777 inside the container | `docker exec <c> chown -R 7777:7777 /home/pok/arkserver/ShooterGame/Saved` |

## References

- Plugin source: `games/ark/scripts/game-specific-logic.sh`
- Compose template: `games/ark/docker/docker-compose.template.yml`
- Env configs: `games/ark/environments/{production,staging}.json`
- Presets: `games/ark/presets/`
- Image upstream: [`Acekorneya/Ark-Survival-Ascended-Server`](https://github.com/Acekorneya/Ark-Survival-Ascended-Server)
