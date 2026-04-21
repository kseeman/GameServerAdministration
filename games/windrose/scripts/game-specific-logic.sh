#!/bin/bash

# Windrose Game Plugin - Game-specific server management functions
# Uses the indifferentbroccoli/windrose-server-docker image which runs the
# Windows server binary via Wine. Config flows through environment variables
# plus an injected ServerDescription.json file in the volume.
#
# Windrose has no RCON, no REST API, and no Steam query port, so health checks
# are limited to verifying the container is running.

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
    source "${REPO_ROOT}/scripts/shared/server-utils.sh"
fi

# Windrose-specific paths
WINDROSE_DOCKER_DIR="${REPO_ROOT}/games/windrose/docker"
WINDROSE_PRESETS_DIR="${REPO_ROOT}/games/windrose/presets"
WINDROSE_VOLUME_MOUNT="/home/steam/server-files"

# --- Preset resolution ---

windrose_resolve_preset() {
    local preset_file="$1"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${WINDROSE_PRESETS_DIR}/${inherits}"
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

windrose_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"
    echo "$preset" > "${state_dir}/windrose-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

windrose_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/windrose-${env}-${instance}.preset"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- Core server operations ---
#
# ServerDescription.json is managed by the upstream container entrypoint
# (GENERATE_SETTINGS=true). It reads INVITE_CODE, SERVER_NAME, SERVER_PASSWORD,
# MAX_PLAYERS, USE_DIRECT_CONNECTION, SERVER_PORT, USER_SELECTED_REGION from the
# environment and writes them into /home/steam/server-files/R5/ServerDescription.json
# at startup. Runtime-generated fields (PersistentServerId, WorldIslandId, Version)
# are owned by the game itself and preserved across restarts.

windrose_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"
    local preset="$4"

    log_info "Starting Windrose server: $instance (env: $env, preset: $preset)"

    local container_name
    container_name=$(get_container_name "windrose" "$instance" "$env")
    local volume_name
    volume_name=$(get_volume_name "windrose" "$instance" "$env")
    local preset_file="${WINDROSE_PRESETS_DIR}/${preset}.json"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if container_running "$container_name"; then
        log_warning "Server already running: $container_name"
        return 1
    fi

    local ports
    ports=($(get_port_assignments "windrose" "$instance" "$env"))
    local game_port="${ports[0]}"

    log_info "Using ports: Game=${game_port} (TCP+UDP)"

    # Infrastructure settings from env config
    local env_config
    env_config=$(get_game_env_config "windrose" "$env")
    local base_name="Windrose"
    local instance_desc="$instance"
    local invite_code=""
    local password=""
    local max_players=10
    local region="auto"
    local restart_policy="unless-stopped"
    local memory_limit="16g"
    local update_on_start="true"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        base_name=$(jq -r '.server_infrastructure.base_server_name // "Windrose"' "$env_config")
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        invite_code=$(jq -r '.server_infrastructure.invite_code // ""' "$env_config")
        password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 10" "$env_config")
        region=$(jq -r '.server_infrastructure.region // "auto"' "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "16g"' "$env_config")
        local update_raw
        update_raw=$(jq -r '.game.update_on_boot // true' "$env_config")
        [[ "$update_raw" == "true" ]] && update_on_start="true" || update_on_start="false"
    fi

    local server_name="${base_name} - ${instance_desc}"

    # Windrose invite code must be 6+ alphanumeric
    if [[ -z "$invite_code" || "$invite_code" == "CHANGEME" ]]; then
        log_error "invite_code not set in $env_config (server_infrastructure.invite_code)"
        log_info "The Windrose invite code must be at least 6 alphanumeric characters"
        return 1
    fi
    if [[ ! "$invite_code" =~ ^[a-zA-Z0-9]{6,}$ ]]; then
        log_error "invite_code '$invite_code' must be at least 6 alphanumeric characters"
        return 1
    fi

    # Generate docker-compose file from template
    local compose_file="${REPO_ROOT}/docker-compose-windrose-${env}-${instance}.yml"
    local template_file="${WINDROSE_DOCKER_DIR}/docker-compose.template.yml"

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
    INVITE_CODE="$invite_code" \
    SERVER_NAME="$server_name" \
    SERVER_PASSWORD="$password" \
    MAX_PLAYERS="$max_players" \
    USER_SELECTED_REGION="$region" \
    envsubst < "$template_file" > "$compose_file"

    # Ensure volume exists
    if ! volume_exists "$volume_name"; then
        log_info "Creating Docker volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi

    # Restore from backup before starting, if requested
    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"
        if ! windrose_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi
        log_success "World data restored from backup before server start"
    fi

    log_info "Starting Windrose container: $container_name"
    docker compose -p "$container_name" -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "Windrose server started: $container_name"
        windrose_save_active_preset "$instance" "$env" "$preset"

        sleep 3
        echo
        echo "=== Server Information ==="
        echo "  Game: windrose"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Game Port: $game_port (TCP+UDP)"
        echo "  Invite Code: $invite_code"
        echo "  Max Players: $max_players"
        echo "  Region: $region"
        echo
        echo "  Note: first start pulls the image and runs UPDATE_ON_START; allow several minutes."
        return 0
    else
        log_error "Failed to start Windrose server: $container_name"
        return 1
    fi
}

windrose_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping Windrose server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "windrose" "$instance" "$env")
    local compose_file="${REPO_ROOT}/docker-compose-windrose-${env}-${instance}.yml"

    local stop_rc=0
    if [[ -f "$compose_file" ]]; then
        docker compose -p "$container_name" -f "$compose_file" down || stop_rc=$?
    else
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null || stop_rc=$?
            docker rm "$container_name" 2>/dev/null || true
        fi
    fi

    if [[ $stop_rc -eq 0 ]]; then
        log_success "Windrose server stopped: $container_name"
        return 0
    else
        log_error "Failed to stop Windrose server: $container_name"
        return 1
    fi
}

windrose_health_check() {
    local instance="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "windrose" "$instance" "$env")

    if ! container_running "$container_name"; then
        log_error "Windrose server health check failed: container not running"
        return 1
    fi

    log_success "Windrose server health check passed: $instance (running)"
    return 0
}

# --- Config swap ---

windrose_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping Windrose config: $instance -> $new_preset (env: $env)"

    local new_preset_file="${WINDROSE_PRESETS_DIR}/${new_preset}.json"

    if ! windrose_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    log_info "Creating pre-swap emergency backup..."
    create_emergency_backup "config-swap" "windrose" "$instance" "$env" >/dev/null || true

    log_info "Stopping server for config swap..."
    windrose_stop_server "$instance" "$env"

    log_info "Starting server with new preset: $new_preset"
    if windrose_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed: $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

windrose_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"
    local active_preset="$4"

    log_info "Backing up Windrose data: $instance (env: $env)"

    local volume_name
    volume_name=$(get_volume_name "windrose" "$instance" "$env")

    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    if [[ -z "$active_preset" ]]; then
        active_preset=$(windrose_get_active_preset "$instance" "$env")
    fi

    if [[ -z "$backup_name" ]]; then
        backup_name="${active_preset:-unknown}_${instance}_${env}_$(date +%Y%m%d_%H%M%S)"
    fi

    local backup_dir="${REPO_ROOT}/backups/${env}/${instance}"
    local backup_file="${backup_dir}/${backup_name}.tar.gz"
    local meta_file="${backup_dir}/${backup_name}.meta.json"
    mkdir -p "$backup_dir"

    log_info "Creating backup: $(basename "$backup_file")"

    # Windrose has no save-RPC; best we can do is warn when live-tarring
    local container_name
    container_name=$(get_container_name "windrose" "$instance" "$env")
    if container_running "$container_name"; then
        log_warning "Server is running — Windrose has no save API; backup may capture in-flight writes"
    fi

    local temp_container="temp-windrose-extract-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:${WINDROSE_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    mkdir -p "${temp_dir}/R5"
    docker cp "${temp_container}:${WINDROSE_VOLUME_MOUNT}/R5/Saved" "${temp_dir}/R5/" 2>/dev/null || true
    docker cp "${temp_container}:${WINDROSE_VOLUME_MOUNT}/R5/ServerDescription.json" "${temp_dir}/R5/" 2>/dev/null || true

    docker rm -f "$temp_container" >/dev/null 2>&1

    local ports
    ports=($(get_port_assignments "windrose" "$instance" "$env"))
    local env_config
    env_config=$(get_game_env_config "windrose" "$env")
    local server_name="Unknown"
    local max_players=10
    if [[ -f "$env_config" ]]; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 10" "$env_config")
    fi

    cat > "$meta_file" << META_EOF
{
    "game": "windrose",
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
        "max_players": $max_players
    },
    "volume_name": "$volume_name",
    "container_name": "windrose-${env}-${instance}",
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

windrose_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring Windrose data: $instance from $backup_file (env: $env)"

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
    container_name=$(get_container_name "windrose" "$instance" "$env")
    if container_running "$container_name"; then
        log_error "Cannot restore while server is running. Stop the server first."
        return 1
    fi

    local volume_name
    volume_name=$(get_volume_name "windrose" "$instance" "$env")

    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    if [[ ! -d "$temp_dir/R5" ]]; then
        log_error "Backup missing R5/ directory"
        rm -rf "$temp_dir"
        return 1
    fi

    local temp_container="temp-windrose-restore-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:${WINDROSE_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    log_info "Clearing existing R5/Saved and R5/ServerDescription.json in volume..."
    docker exec "$temp_container" sh -c "rm -rf ${WINDROSE_VOLUME_MOUNT}/R5/Saved ${WINDROSE_VOLUME_MOUNT}/R5/ServerDescription.json" 2>/dev/null || true
    docker exec "$temp_container" mkdir -p "${WINDROSE_VOLUME_MOUNT}/R5" 2>/dev/null

    log_info "Restoring R5 contents from backup..."
    if [[ -d "$temp_dir/R5/Saved" ]]; then
        docker cp "$temp_dir/R5/Saved" "$temp_container:${WINDROSE_VOLUME_MOUNT}/R5/"
    fi
    if [[ -f "$temp_dir/R5/ServerDescription.json" ]]; then
        docker cp "$temp_dir/R5/ServerDescription.json" "$temp_container:${WINDROSE_VOLUME_MOUNT}/R5/"
    fi

    docker exec "$temp_container" chown -R 1000:1000 "${WINDROSE_VOLUME_MOUNT}" 2>/dev/null

    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "Windrose restore completed"
    return 0
}

# --- Utilities ---

windrose_get_ports() {
    local instance="$1"
    local env="$2"
    get_port_assignments "windrose" "$instance" "$env"
}

windrose_validate_preset() {
    local preset_file="$1"
    local instance="$2"
    local env="$3"

    log_info "Validating Windrose preset: $preset_file"

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
        local parent_file="${WINDROSE_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "Windrose preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f windrose_start_server windrose_stop_server
export -f windrose_health_check windrose_config_swap
export -f windrose_backup_data windrose_restore_data
export -f windrose_get_ports windrose_validate_preset
export -f windrose_resolve_preset
export -f windrose_save_active_preset windrose_get_active_preset
