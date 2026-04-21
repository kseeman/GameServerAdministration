#!/bin/bash

# Smalland Game Plugin - Game-specific server management functions
# Uses a locally-built image (smalland-server:latest) based on cm2network/steamcmd
# that installs Smalland (Steam app 808040) on first run and translates env vars
# into Smalland's URL-style CLI args.
#
# Smalland has no RCON, no REST API, and no separate query port; health checks
# are limited to verifying the container is running.

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
    source "${REPO_ROOT}/scripts/shared/server-utils.sh"
fi

# Smalland-specific paths
SMALLAND_DOCKER_DIR="${REPO_ROOT}/games/smalland/docker"
SMALLAND_PRESETS_DIR="${REPO_ROOT}/games/smalland/presets"
SMALLAND_IMAGE_TAG="smalland-server:latest"

# --- Preset resolution ---

smalland_resolve_preset() {
    local preset_file="$1"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${SMALLAND_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file (inherited by $(basename "$preset_file"))"
            return 1
        fi

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

smalland_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"
    echo "$preset" > "${state_dir}/smalland-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

smalland_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/smalland-${env}-${instance}.preset"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- Image build ---

# Build smalland-server:latest from games/smalland/docker/Dockerfile.
# docker build uses its cache so this is a no-op when Dockerfile/entrypoint.sh
# haven't changed.
smalland_build_image() {
    log_info "Building ${SMALLAND_IMAGE_TAG} from ${SMALLAND_DOCKER_DIR}"
    if ! docker build -t "$SMALLAND_IMAGE_TAG" "$SMALLAND_DOCKER_DIR"; then
        log_error "Failed to build ${SMALLAND_IMAGE_TAG}"
        return 1
    fi
    log_success "${SMALLAND_IMAGE_TAG} built"
    return 0
}

# --- Core server operations ---

smalland_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"
    local preset="$4"

    log_info "Starting Smalland server: $instance (env: $env, preset: $preset)"

    local container_name
    container_name=$(get_container_name "smalland" "$instance" "$env")
    local volume_name
    volume_name=$(get_volume_name "smalland" "$instance" "$env")
    local preset_file="${SMALLAND_PRESETS_DIR}/${preset}.json"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if container_running "$container_name"; then
        log_warning "Server already running: $container_name"
        return 1
    fi

    local ports
    ports=($(get_port_assignments "smalland" "$instance" "$env"))
    local game_port="${ports[0]}"

    log_info "Using ports: Game=${game_port} (UDP)"

    # Resolve preset (game_settings — all the modifiers)
    local resolved
    resolved=$(smalland_resolve_preset "$preset_file") || return 1

    local friendly_fire peaceful_mode keep_inventory no_deterioration
    local tamed_creatures_immortal private crossplay
    local length_of_day_seconds length_of_season_seconds
    local creature_health_modifier creature_damage_modifier creature_respawn_rate_modifier
    local resource_respawn_rate_modifier creature_spawn_chance_modifier
    local crafting_time_modifier crafting_fuel_modifier
    local storm_frequency_modifier nourishment_loss_modifier fall_damage_modifier

    friendly_fire=$(echo "$resolved" | jq -r '.game_settings.friendly_fire // 0')
    peaceful_mode=$(echo "$resolved" | jq -r '.game_settings.peaceful_mode // 0')
    keep_inventory=$(echo "$resolved" | jq -r '.game_settings.keep_inventory // 0')
    no_deterioration=$(echo "$resolved" | jq -r '.game_settings.no_deterioration // 0')
    tamed_creatures_immortal=$(echo "$resolved" | jq -r '.game_settings.tamed_creatures_immortal // 0')
    private=$(echo "$resolved" | jq -r '.game_settings.private // 0')
    crossplay=$(echo "$resolved" | jq -r '.game_settings.crossplay // 1')
    length_of_day_seconds=$(echo "$resolved" | jq -r '.game_settings.length_of_day_seconds // 1800')
    length_of_season_seconds=$(echo "$resolved" | jq -r '.game_settings.length_of_season_seconds // 10800')
    creature_health_modifier=$(echo "$resolved" | jq -r '.game_settings.creature_health_modifier // 100')
    creature_damage_modifier=$(echo "$resolved" | jq -r '.game_settings.creature_damage_modifier // 100')
    creature_respawn_rate_modifier=$(echo "$resolved" | jq -r '.game_settings.creature_respawn_rate_modifier // 100')
    resource_respawn_rate_modifier=$(echo "$resolved" | jq -r '.game_settings.resource_respawn_rate_modifier // 100')
    creature_spawn_chance_modifier=$(echo "$resolved" | jq -r '.game_settings.creature_spawn_chance_modifier // 100')
    crafting_time_modifier=$(echo "$resolved" | jq -r '.game_settings.crafting_time_modifier // 100')
    crafting_fuel_modifier=$(echo "$resolved" | jq -r '.game_settings.crafting_fuel_modifier // 100')
    storm_frequency_modifier=$(echo "$resolved" | jq -r '.game_settings.storm_frequency_modifier // 100')
    nourishment_loss_modifier=$(echo "$resolved" | jq -r '.game_settings.nourishment_loss_modifier // 100')
    fall_damage_modifier=$(echo "$resolved" | jq -r '.game_settings.fall_damage_modifier // 100')

    # Infrastructure from env config
    local env_config
    env_config=$(get_game_env_config "smalland" "$env")
    local base_name="Smalland Server"
    local instance_desc="$instance"
    local server_password=""
    local eos_deployment_id=""
    local eos_client_id=""
    local eos_client_secret=""
    local eos_private_key=""
    local world_name="World"
    local restart_policy="unless-stopped"
    local memory_limit="8g"
    local update_on_start="true"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        base_name=$(jq -r '.server_infrastructure.base_server_name // "Smalland Server"' "$env_config")
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        server_password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        eos_deployment_id=$(jq -r '.server_infrastructure.eos_deployment_id // ""' "$env_config")
        eos_client_id=$(jq -r '.server_infrastructure.eos_client_id // ""' "$env_config")
        eos_client_secret=$(jq -r '.server_infrastructure.eos_client_secret // ""' "$env_config")
        eos_private_key=$(jq -r '.server_infrastructure.eos_private_key // ""' "$env_config")
        world_name=$(jq -r ".instances.\"$instance\".world_name // \"World\"" "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "8g"' "$env_config")
        local update_raw
        update_raw=$(jq -r '.game.update_on_boot // true' "$env_config")
        [[ "$update_raw" == "true" ]] && update_on_start="true" || update_on_start="false"
    fi

    local server_name="${base_name} - ${instance_desc}"

    if [[ -z "$eos_deployment_id" || -z "$eos_client_id" || -z "$eos_client_secret" ]]; then
        log_error "Missing EOS credentials in $env_config (server_infrastructure.eos_*)"
        log_info "Smalland requires DeploymentId, ClientId, and ClientSecret to register with Epic Online Services"
        return 1
    fi

    # Build the image (cache makes this fast on subsequent starts)
    if ! smalland_build_image; then
        return 1
    fi

    # Generate docker-compose file from template
    local compose_file="${REPO_ROOT}/docker-compose-smalland-${env}-${instance}.yml"
    local template_file="${SMALLAND_DOCKER_DIR}/docker-compose.template.yml"

    if [[ ! -f "$template_file" ]]; then
        log_error "Docker compose template not found: $template_file"
        return 1
    fi

    log_info "Generating compose file: $compose_file"

    CONTAINER_NAME="$container_name" \
    VOLUME_NAME="$volume_name" \
    GAME_PORT="$game_port" \
    RESTART_POLICY="$restart_policy" \
    MEMORY_LIMIT="$memory_limit" \
    UPDATE_ON_START="$update_on_start" \
    SERVER_NAME="$server_name" \
    WORLD_NAME="$world_name" \
    SERVER_PASSWORD="$server_password" \
    FRIENDLY_FIRE="$friendly_fire" \
    PEACEFUL_MODE="$peaceful_mode" \
    KEEP_INVENTORY="$keep_inventory" \
    NO_DETERIORATION="$no_deterioration" \
    TAMED_CREATURES_IMMORTAL="$tamed_creatures_immortal" \
    PRIVATE="$private" \
    CROSSPLAY="$crossplay" \
    LENGTH_OF_DAY_SECONDS="$length_of_day_seconds" \
    LENGTH_OF_SEASON_SECONDS="$length_of_season_seconds" \
    CREATURE_HEALTH_MODIFIER="$creature_health_modifier" \
    CREATURE_DAMAGE_MODIFIER="$creature_damage_modifier" \
    CREATURE_RESPAWN_RATE_MODIFIER="$creature_respawn_rate_modifier" \
    RESOURCE_RESPAWN_RATE_MODIFIER="$resource_respawn_rate_modifier" \
    CREATURE_SPAWN_CHANCE_MODIFIER="$creature_spawn_chance_modifier" \
    CRAFTING_TIME_MODIFIER="$crafting_time_modifier" \
    CRAFTING_FUEL_MODIFIER="$crafting_fuel_modifier" \
    STORM_FREQUENCY_MODIFIER="$storm_frequency_modifier" \
    NOURISHMENT_LOSS_MODIFIER="$nourishment_loss_modifier" \
    FALL_DAMAGE_MODIFIER="$fall_damage_modifier" \
    EOS_DEPLOYMENT_ID="$eos_deployment_id" \
    EOS_CLIENT_ID="$eos_client_id" \
    EOS_CLIENT_SECRET="$eos_client_secret" \
    EOS_PRIVATE_KEY="$eos_private_key" \
    envsubst < "$template_file" > "$compose_file"

    if ! volume_exists "$volume_name"; then
        log_info "Creating Docker volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi

    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"
        if ! smalland_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi
        log_success "World data restored from backup before server start"
    fi

    log_info "Starting Smalland container: $container_name"
    docker compose -p "$container_name" -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "Smalland server started: $container_name"
        smalland_save_active_preset "$instance" "$env" "$preset"

        sleep 3
        echo
        echo "=== Server Information ==="
        echo "  Game: smalland"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Game Port: $game_port (UDP)"
        echo "  World: $world_name"
        echo "  Server Name: $server_name"
        echo
        echo "  Note: first start builds the image and runs steamcmd to download app 808040;"
        echo "        allow 5-10 minutes before the server is reachable."
        return 0
    else
        log_error "Failed to start Smalland server: $container_name"
        return 1
    fi
}

smalland_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping Smalland server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "smalland" "$instance" "$env")
    local compose_file="${REPO_ROOT}/docker-compose-smalland-${env}-${instance}.yml"

    if [[ -f "$compose_file" ]]; then
        docker compose -p "$container_name" -f "$compose_file" down
    else
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null
            docker rm "$container_name" 2>/dev/null
        fi
    fi

    # Compose down only stops containers tracked under the -p project. If the
    # container was created outside this project, fall back to direct stop/rm.
    if container_exists "$container_name"; then
        log_warning "Container $container_name not cleaned up by compose down; falling back to docker stop/rm"
        docker stop "$container_name" 2>/dev/null || true
        docker rm "$container_name" 2>/dev/null || true
    fi

    if container_exists "$container_name"; then
        log_error "Container $container_name still exists after stop attempt"
        return 1
    fi

    log_success "Smalland server stopped: $container_name"
    return 0
}

smalland_health_check() {
    local instance="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "smalland" "$instance" "$env")

    if ! container_running "$container_name"; then
        log_error "Smalland server health check failed: container not running"
        return 1
    fi

    log_success "Smalland server health check passed: $instance (running)"
    return 0
}

# --- Config swap ---

smalland_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping Smalland config: $instance -> $new_preset (env: $env)"

    local new_preset_file="${SMALLAND_PRESETS_DIR}/${new_preset}.json"

    if ! smalland_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    log_info "Creating pre-swap emergency backup..."
    create_emergency_backup "config-swap" "smalland" "$instance" "$env" >/dev/null || true

    log_info "Stopping server for config swap..."
    smalland_stop_server "$instance" "$env"

    log_info "Starting server with new preset: $new_preset"
    if smalland_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed: $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

smalland_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"
    local active_preset="$4"

    log_info "Backing up Smalland data: $instance (env: $env)"

    local volume_name
    volume_name=$(get_volume_name "smalland" "$instance" "$env")

    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    if [[ -z "$active_preset" ]]; then
        active_preset=$(smalland_get_active_preset "$instance" "$env")
    fi

    if [[ -z "$backup_name" ]]; then
        backup_name="${active_preset:-unknown}_${instance}_${env}_$(date +%Y%m%d_%H%M%S)"
    fi

    local backup_dir="${REPO_ROOT}/backups/${env}/${instance}"
    local backup_file="${backup_dir}/${backup_name}.tar.gz"
    local meta_file="${backup_dir}/${backup_name}.meta.json"
    mkdir -p "$backup_dir"

    log_info "Creating backup: $(basename "$backup_file")"

    local container_name
    container_name=$(get_container_name "smalland" "$instance" "$env")
    if container_running "$container_name"; then
        log_warning "Server is running — Smalland has no save RPC; backup may capture in-flight writes"
    fi

    local temp_container="temp-smalland-extract-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:/home/steam/smalland" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    mkdir -p "${temp_dir}/SMALLAND"
    docker cp "${temp_container}:/home/steam/smalland/SMALLAND/Saved" "${temp_dir}/SMALLAND/" 2>/dev/null || true

    docker rm -f "$temp_container" >/dev/null 2>&1

    local ports
    ports=($(get_port_assignments "smalland" "$instance" "$env"))
    local env_config
    env_config=$(get_game_env_config "smalland" "$env")
    local server_name="Unknown"
    local max_players=8
    local world_name="Unknown"
    if [[ -f "$env_config" ]]; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 8" "$env_config")
        world_name=$(jq -r ".instances.\"$instance\".world_name // \"Unknown\"" "$env_config")
    fi

    cat > "$meta_file" << META_EOF
{
    "game": "smalland",
    "instance": "$instance",
    "environment": "$env",
    "active_preset": "${active_preset:-unknown}",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "infrastructure": {
        "ports": {
            "game": ${ports[0]}
        },
        "server_name": "$server_name",
        "world_name": "$world_name",
        "max_players": $max_players
    },
    "volume_name": "$volume_name",
    "container_name": "smalland-${env}-${instance}",
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

smalland_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring Smalland data: $instance from $backup_file (env: $env)"

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

    local container_name
    container_name=$(get_container_name "smalland" "$instance" "$env")
    if container_running "$container_name"; then
        log_error "Cannot restore while server is running. Stop the server first."
        return 1
    fi

    local volume_name
    volume_name=$(get_volume_name "smalland" "$instance" "$env")

    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ ! -d "$temp_dir/SMALLAND/Saved" ]]; then
        log_error "Backup missing SMALLAND/Saved/ directory"
        rm -rf "$temp_dir"
        return 1
    fi

    local temp_container="temp-smalland-restore-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:/home/steam/smalland" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    log_info "Clearing existing SMALLAND/Saved in volume..."
    docker exec "$temp_container" sh -c "rm -rf /home/steam/smalland/SMALLAND/Saved" 2>/dev/null || true
    docker exec "$temp_container" mkdir -p "/home/steam/smalland/SMALLAND" 2>/dev/null

    log_info "Restoring SMALLAND/Saved from backup..."
    docker cp "$temp_dir/SMALLAND/Saved" "$temp_container:/home/steam/smalland/SMALLAND/"

    docker exec "$temp_container" chown -R 1000:1000 /home/steam/smalland 2>/dev/null

    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "Smalland restore completed"
    return 0
}

# --- Utilities ---

smalland_get_ports() {
    local instance="$1"
    local env="$2"
    get_port_assignments "smalland" "$instance" "$env"
}

smalland_validate_preset() {
    local preset_file="$1"
    local instance="$2"
    local env="$3"

    log_info "Validating Smalland preset: $preset_file"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if ! jq empty "$preset_file" 2>/dev/null; then
        log_error "Preset file is not valid JSON: $preset_file"
        return 1
    fi

    if ! jq -e '.metadata' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'metadata' section: $preset_file"
        return 1
    fi

    if ! jq -e '.game_settings' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'game_settings' section: $preset_file"
        return 1
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")
    if [[ -n "$inherits" ]]; then
        local parent_file="${SMALLAND_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "Smalland preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f smalland_start_server smalland_stop_server
export -f smalland_health_check smalland_config_swap
export -f smalland_backup_data smalland_restore_data
export -f smalland_get_ports smalland_validate_preset
export -f smalland_resolve_preset smalland_build_image
export -f smalland_save_active_preset smalland_get_active_preset
