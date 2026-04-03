#!/bin/bash

# Minecraft Game Plugin - Game-specific server management functions
# Uses the itzg/minecraft-server Docker image which handles server type selection,
# mod installation, server.properties generation from env vars, RCON, and health checks.
#
# Much simpler than ARK/Palworld — no ini injection, no sidecar, no Proton.
# All game settings flow through Docker env vars to the itzg image.

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/shared/server-utils.sh"

# Minecraft-specific paths
MINECRAFT_DOCKER_DIR="${REPO_ROOT}/games/minecraft/docker"
MINECRAFT_PRESETS_DIR="${REPO_ROOT}/games/minecraft/presets"

# --- Preset resolution ---

# Resolve a preset with inheritance.
# game_settings merges (child overrides parent).
# server_type, minecraft_version, mod_config, jvm_config: child fully replaces parent.
minecraft_resolve_preset() {
    local preset_file="$1"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${MINECRAFT_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file (inherited by $(basename "$preset_file"))"
            return 1
        fi

        # Deep merge game_settings, child top-level keys override parent
        jq -s '
            .[0] as $parent | .[1] as $child |
            $parent * $child |
            .game_settings = ($parent.game_settings * $child.game_settings)
        ' "$parent_file" "$preset_file"
    else
        jq '.' "$preset_file"
    fi
}

# --- State tracking ---

minecraft_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"
    echo "$preset" > "${state_dir}/minecraft-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

minecraft_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/minecraft-${env}-${instance}.preset"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- Core server operations ---

minecraft_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"  # optional
    local preset="$4"

    log_info "Starting Minecraft server: $instance (env: $env, preset: $preset)"

    local container_name
    container_name=$(get_container_name "minecraft" "$instance" "$env")
    local volume_name
    volume_name=$(get_volume_name "minecraft" "$instance" "$env")
    local preset_file="${MINECRAFT_PRESETS_DIR}/${preset}.json"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if container_running "$container_name"; then
        log_warning "Server already running: $container_name"
        return 1
    fi

    # Get port assignments
    local ports
    ports=($(get_port_assignments "minecraft" "$instance" "$env"))
    local game_port="${ports[0]}"
    local rcon_port="${ports[2]}"

    log_info "Using ports: Game=$game_port, RCON=$rcon_port"

    # Resolve preset with inheritance
    local resolved
    resolved=$(minecraft_resolve_preset "$preset_file") || return 1

    # Extract preset values
    local server_type
    server_type=$(echo "$resolved" | jq -r '.server_type // "VANILLA"')
    local mc_version
    mc_version=$(echo "$resolved" | jq -r '.minecraft_version // "LATEST"')
    local memory
    memory=$(echo "$resolved" | jq -r '.jvm_config.memory // "4G"')
    local use_aikar_flags
    use_aikar_flags=$(echo "$resolved" | jq -r '.jvm_config.use_aikar_flags // "true"')
    local modrinth_projects
    modrinth_projects=$(echo "$resolved" | jq -r '.mod_config.modrinth_projects // ""')
    local mods
    mods=$(echo "$resolved" | jq -r '.mod_config.mods // ""')

    # Extract game_settings and convert to env var format
    local difficulty
    difficulty=$(echo "$resolved" | jq -r '.game_settings.difficulty // "normal"')
    local gamemode
    gamemode=$(echo "$resolved" | jq -r '.game_settings.gamemode // "survival"')
    local pvp
    pvp=$(echo "$resolved" | jq -r '.game_settings.pvp // "true"')
    local max_players
    max_players=$(echo "$resolved" | jq -r '.game_settings["max-players"] // 20')
    local view_distance
    view_distance=$(echo "$resolved" | jq -r '.game_settings["view-distance"] // 10')
    local simulation_distance
    simulation_distance=$(echo "$resolved" | jq -r '.game_settings["simulation-distance"] // 10')
    local spawn_protection
    spawn_protection=$(echo "$resolved" | jq -r '.game_settings["spawn-protection"] // 16')
    local allow_flight
    allow_flight=$(echo "$resolved" | jq -r '.game_settings["allow-flight"] // "false"')
    local motd
    motd=$(echo "$resolved" | jq -r '.game_settings.motd // "A Minecraft Server"')
    local enable_command_block
    enable_command_block=$(echo "$resolved" | jq -r '.game_settings["enable-command-block"] // "false"')
    local max_world_size
    max_world_size=$(echo "$resolved" | jq -r '.game_settings["max-world-size"] // 29999984')
    local level_type
    level_type=$(echo "$resolved" | jq -r '.game_settings["level-type"] // "minecraft\\:normal"')
    local online_mode
    online_mode=$(echo "$resolved" | jq -r '.game_settings["online-mode"] // "true"')
    local allow_nether
    allow_nether=$(echo "$resolved" | jq -r '.game_settings["allow-nether"] // "true"')
    local spawn_monsters
    spawn_monsters=$(echo "$resolved" | jq -r '.game_settings["spawn-monsters"] // "true"')
    local spawn_animals
    spawn_animals=$(echo "$resolved" | jq -r '.game_settings["spawn-animals"] // "true"')
    local generate_structures
    generate_structures=$(echo "$resolved" | jq -r '.game_settings["generate-structures"] // "true"')
    local max_tick_time
    max_tick_time=$(echo "$resolved" | jq -r '.game_settings["max-tick-time"] // 60000')
    local entity_broadcast_range
    entity_broadcast_range=$(echo "$resolved" | jq -r '.game_settings["entity-broadcast-range-percentage"] // 100')

    # Get infrastructure from environment config
    local env_config
    env_config=$(get_game_env_config "minecraft" "$env")
    local server_name="Minecraft Server"
    local rcon_password="minecraft"
    local restart_policy="unless-stopped"
    local memory_limit="8g"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        local base_name
        base_name=$(jq -r '.server_infrastructure.base_server_name // "Minecraft"' "$env_config")
        local instance_desc
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        server_name="${base_name} - ${instance_desc}"
        rcon_password=$(jq -r '.server_infrastructure.rcon_password // "minecraft"' "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "8g"' "$env_config")
    fi

    # Generate docker-compose file from template
    local compose_file="${REPO_ROOT}/docker-compose-minecraft-${env}-${instance}.yml"
    local template_file="${MINECRAFT_DOCKER_DIR}/docker-compose.template.yml"

    if [[ ! -f "$template_file" ]]; then
        log_error "Docker compose template not found: $template_file"
        return 1
    fi

    log_info "Generating compose file: $compose_file"

    CONTAINER_NAME="$container_name" \
    VOLUME_NAME="$volume_name" \
    GAME_PORT="$game_port" \
    RCON_PORT="$rcon_port" \
    RESTART_POLICY="$restart_policy" \
    MEMORY_LIMIT="$memory_limit" \
    SERVER_TYPE="$server_type" \
    MINECRAFT_VERSION="$mc_version" \
    MEMORY="$memory" \
    USE_AIKAR_FLAGS="$use_aikar_flags" \
    RCON_PASSWORD="$rcon_password" \
    MODRINTH_PROJECTS="$modrinth_projects" \
    MODS="$mods" \
    SERVER_NAME="$server_name" \
    MOTD="$motd" \
    DIFFICULTY="$difficulty" \
    GAMEMODE="$gamemode" \
    PVP="$pvp" \
    MAX_PLAYERS="$max_players" \
    VIEW_DISTANCE="$view_distance" \
    SIMULATION_DISTANCE="$simulation_distance" \
    SPAWN_PROTECTION="$spawn_protection" \
    ALLOW_FLIGHT="$allow_flight" \
    ENABLE_COMMAND_BLOCK="$enable_command_block" \
    MAX_WORLD_SIZE="$max_world_size" \
    LEVEL_TYPE="$level_type" \
    ONLINE_MODE="$online_mode" \
    ALLOW_NETHER="$allow_nether" \
    SPAWN_MONSTERS="$spawn_monsters" \
    SPAWN_ANIMALS="$spawn_animals" \
    GENERATE_STRUCTURES="$generate_structures" \
    MAX_TICK_TIME="$max_tick_time" \
    ENTITY_BROADCAST_RANGE_PERCENTAGE="$entity_broadcast_range" \
    envsubst < "$template_file" > "$compose_file"

    # Create Docker volume if it doesn't exist
    if ! volume_exists "$volume_name"; then
        log_info "Creating Docker volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi

    # If backup file specified, restore world data BEFORE starting
    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"
        if ! minecraft_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi
        log_success "World data restored from backup before server start"
    fi

    # Start server
    log_info "Starting Minecraft container: $container_name"
    docker compose -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "Minecraft server started: $container_name"
        minecraft_save_active_preset "$instance" "$env" "$preset"

        sleep 3
        echo
        echo "=== Server Information ==="
        echo "  Game: minecraft"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Type: $server_type"
        echo "  Version: $mc_version"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Game Port: $game_port"
        echo "  RCON Port: $rcon_port"
        echo "  Memory: $memory"
        [[ -n "$modrinth_projects" ]] && echo "  Mods (Modrinth): $modrinth_projects"
        return 0
    else
        log_error "Failed to start Minecraft server: $container_name"
        return 1
    fi
}

minecraft_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping Minecraft server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "minecraft" "$instance" "$env")
    local compose_file="${REPO_ROOT}/docker-compose-minecraft-${env}-${instance}.yml"

    # Save world via RCON before stopping
    if container_running "$container_name"; then
        log_info "Sending save-all via RCON..."
        minecraft_rcon_command "$instance" "$env" "save-all" 2>/dev/null || true
        sleep 3
    fi

    if [[ -f "$compose_file" ]]; then
        docker compose -f "$compose_file" down
    else
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null
            docker rm "$container_name" 2>/dev/null
        fi
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Minecraft server stopped: $container_name"
        return 0
    else
        log_error "Failed to stop Minecraft server: $container_name"
        return 1
    fi
}

minecraft_restart_server() {
    local instance="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "minecraft" "$instance" "$env")

    if ! container_running "$container_name"; then
        log_warning "Server not running: $instance"
        local active_preset
        active_preset=$(minecraft_get_active_preset "$instance" "$env")
        if [[ "$active_preset" == "unknown" ]]; then
            local env_config
            env_config=$(get_game_env_config "minecraft" "$env")
            active_preset=$(jq -r ".instances.\"$instance\".default_preset // \"default\"" "$env_config" 2>/dev/null || echo "default")
        fi
        minecraft_start_server "$instance" "$env" "" "$active_preset"
        return $?
    fi

    local compose_file="${REPO_ROOT}/docker-compose-minecraft-${env}-${instance}.yml"
    if [[ -f "$compose_file" ]]; then
        docker compose -f "$compose_file" restart
    else
        docker restart "$container_name"
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Minecraft server restarted: $container_name"
        return 0
    else
        log_error "Failed to restart Minecraft server: $container_name"
        return 1
    fi
}

minecraft_health_check() {
    local context="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "minecraft" "$context" "$env")

    if ! container_running "$container_name"; then
        log_error "Minecraft server health check failed: container not running"
        return 1
    fi

    # The itzg image has a built-in healthcheck via mc-health
    local health_status
    health_status=$(docker inspect "$container_name" --format='{{.State.Health.Status}}' 2>/dev/null)

    case "$health_status" in
        healthy)
            log_success "Minecraft server health check passed: $context (healthy)"
            return 0
            ;;
        unhealthy)
            log_error "Minecraft server health check failed: $context (unhealthy)"
            return 1
            ;;
        starting)
            log_info "Minecraft server still starting: $context"
            return 0
            ;;
        *)
            # No healthcheck configured or status unknown, fall back to container check
            log_success "Minecraft server health check passed: $context (running)"
            return 0
            ;;
    esac
}

# --- Config swap ---

minecraft_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping Minecraft config: $instance -> $new_preset (env: $env)"

    local new_preset_file="${MINECRAFT_PRESETS_DIR}/${new_preset}.json"

    if ! minecraft_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    # Minecraft requires restart for server.properties changes — no hot swap
    log_info "Creating pre-swap backup..."
    minecraft_backup_data "$instance" "$env" "pre-swap_${new_preset}_$(date +%Y%m%d_%H%M%S)"

    log_info "Stopping server for config swap..."
    minecraft_stop_server "$instance" "$env"

    log_info "Starting server with new preset: $new_preset"
    if minecraft_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed: $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

minecraft_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"
    local active_preset="$4"

    log_info "Backing up Minecraft data: $instance (env: $env)"

    local volume_name
    volume_name=$(get_volume_name "minecraft" "$instance" "$env")

    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    if [[ -z "$active_preset" ]]; then
        active_preset=$(minecraft_get_active_preset "$instance" "$env")
    fi

    if [[ -z "$backup_name" ]]; then
        backup_name="${active_preset:-unknown}_${instance}_${env}_$(date +%Y%m%d_%H%M%S)"
    fi

    local backup_dir="${REPO_ROOT}/backups/${env}/${instance}"
    local backup_file="${backup_dir}/${backup_name}.tar.gz"
    local meta_file="${backup_dir}/${backup_name}.meta.json"
    mkdir -p "$backup_dir"

    log_info "Creating backup: $(basename "$backup_file")"

    # Save world via RCON if server is running
    local container_name
    container_name=$(get_container_name "minecraft" "$instance" "$env")
    if container_running "$container_name"; then
        log_info "Server running, triggering save..."
        minecraft_rcon_command "$instance" "$env" "save-all flush" 2>/dev/null || true
        minecraft_rcon_command "$instance" "$env" "save-off" 2>/dev/null || true
        sleep 3
    fi

    # Copy world data from volume
    local temp_container="temp-mc-extract-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "$volume_name:/data" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    docker cp "$temp_container:/data/world" "$temp_dir/" 2>/dev/null || true
    docker cp "$temp_container:/data/server.properties" "$temp_dir/" 2>/dev/null || true

    docker rm -f "$temp_container" >/dev/null 2>&1

    # Re-enable auto-save if server is running
    if container_running "$container_name"; then
        minecraft_rcon_command "$instance" "$env" "save-on" 2>/dev/null || true
    fi

    # Get metadata
    local ports
    ports=($(get_port_assignments "minecraft" "$instance" "$env"))
    local config
    config=$(get_game_env_config "minecraft" "$env")
    local server_name="Unknown"
    local max_players=20
    if [[ -f "$config" ]]; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 20" "$config")
    fi

    cat > "$meta_file" << META_EOF
{
    "game": "minecraft",
    "instance": "$instance",
    "environment": "$env",
    "active_preset": "${active_preset:-unknown}",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "infrastructure": {
        "ports": {
            "game": ${ports[0]},
            "rcon": ${ports[2]}
        },
        "server_name": "$server_name",
        "max_players": $max_players
    },
    "volume_name": "$volume_name",
    "container_name": "minecraft-${env}-${instance}",
    "backup_method": "docker_volume"
}
META_EOF

    (cd "$temp_dir" && tar -czf "$backup_file" .)
    rm -rf "$temp_dir"

    if [[ -f "$backup_file" ]]; then
        local backup_size
        backup_size=$(du -sh "$backup_file" | cut -f1)
        log_success "Backup created successfully: $backup_size"
        log_info "Backup file: $backup_file"
        echo "$backup_file"
        return 0
    else
        log_error "Failed to create backup archive"
        return 1
    fi
}

minecraft_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring Minecraft data: $instance from $backup_file (env: $env)"

    if [[ ! -f "$backup_file" ]]; then
        local found_backup=""
        for search_path in \
            "${REPO_ROOT}/backups/${env}/${instance}/${backup_file}" \
            "${REPO_ROOT}/backups/${env}/*/${backup_file}" \
            "${REPO_ROOT}/backups/*/${backup_file}"; do
            for match in $search_path; do
                if [[ -f "$match" ]]; then
                    found_backup="$match"
                    break 2
                fi
            done
        done

        if [[ -n "$found_backup" ]]; then
            backup_file="$found_backup"
        else
            log_error "Backup file not found: $backup_file"
            return 1
        fi
    fi

    local volume_name
    volume_name=$(get_volume_name "minecraft" "$instance" "$env")

    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ ! -d "$temp_dir/world" ]]; then
        log_error "Backup missing world/ directory"
        rm -rf "$temp_dir"
        return 1
    fi

    local temp_container="temp-mc-restore-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "$volume_name:/data" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    # Replace world data only (server.properties is regenerated by itzg image)
    log_info "Clearing existing world data..."
    docker exec "$temp_container" sh -c "rm -rf /data/world" 2>/dev/null || true

    log_info "Restoring world data from backup..."
    docker cp "$temp_dir/world" "$temp_container:/data/"

    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "Minecraft world restoration completed"
    return 0
}

# --- RCON helper ---

minecraft_rcon_command() {
    local instance="$1"
    local env="$2"
    local command="$3"

    local container_name
    container_name=$(get_container_name "minecraft" "$instance" "$env")

    # rcon-cli in the itzg image reads connection details from container env automatically
    docker exec "$container_name" rcon-cli "$command" 2>/dev/null
}

# --- Utilities ---

minecraft_get_ports() {
    local context="$1"
    local env="$2"
    get_port_assignments "minecraft" "$context" "$env"
}

minecraft_validate_preset() {
    local preset_file="$1"
    local context="$2"
    local env="$3"

    log_info "Validating Minecraft preset: $preset_file"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if ! jq empty "$preset_file" 2>/dev/null; then
        log_error "Preset file is not valid JSON: $preset_file"
        return 1
    fi

    if ! jq -e '.game_settings' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'game_settings' section: $preset_file"
        return 1
    fi

    local server_type
    server_type=$(jq -r '.server_type // empty' "$preset_file")
    if [[ -n "$server_type" ]]; then
        case "$server_type" in
            VANILLA|FORGE|FABRIC|NEOFORGE|PAPER|SPIGOT|BUKKIT|QUILT) ;;
            *)
                log_error "Invalid server_type '$server_type' in preset"
                return 1
                ;;
        esac
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")
    if [[ -n "$inherits" ]]; then
        local parent_file="${MINECRAFT_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "Minecraft preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f minecraft_start_server minecraft_stop_server minecraft_restart_server
export -f minecraft_health_check minecraft_config_swap
export -f minecraft_backup_data minecraft_restore_data
export -f minecraft_get_ports minecraft_validate_preset
export -f minecraft_resolve_preset minecraft_rcon_command
export -f minecraft_save_active_preset minecraft_get_active_preset
