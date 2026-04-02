#!/bin/bash

# Palworld Game Plugin - Game-specific server management functions
# Implements the existing palworld-docker functionality in the new plugin architecture

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/shared/server-utils.sh"

# Palworld-specific paths and configuration
PALWORLD_DOCKER_DIR="${REPO_ROOT}/games/palworld/docker"
PALWORLD_PRESETS_DIR="${REPO_ROOT}/games/palworld/presets"

# --- Preset resolution and state tracking ---

# Resolve a preset JSON file with inheritance, outputting merged game_settings as KEY=VALUE lines
palworld_resolve_preset() {
    local preset_file="$1"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required for preset resolution"
        return 1
    fi

    # Check if this preset inherits from a parent
    local inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${PALWORLD_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file (inherited by $(basename "$preset_file"))"
            return 1
        fi

        # Merge parent game_settings with child game_settings (child overrides parent)
        jq -s '.[0].game_settings * .[1].game_settings | to_entries[] | "\(.key)=\(.value)"' \
            "$parent_file" "$preset_file" | sed 's/^"//;s/"$//'
    else
        # No inheritance, just output this preset's game_settings
        jq -r '.game_settings | to_entries[] | "\(.key)=\(.value)"' "$preset_file"
    fi
}

# Generate PalWorldSettings.ini content from a resolved preset + server infrastructure
# Args: preset_file, env, instance
palworld_generate_settings_ini() {
    local preset_file="$1"
    local env="$2"
    local instance="$3"

    local resolved_settings
    resolved_settings=$(palworld_resolve_preset "$preset_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Build the OptionSettings line: Key=Value,Key=Value,...
    local options=""

    # Add game settings from preset
    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Capitalize booleans: Palworld expects True/False not true/false
        if [[ "$value" == "true" ]]; then
            value="True"
        elif [[ "$value" == "false" ]]; then
            value="False"
        fi
        # Quote string values that contain spaces, commas, or are URLs
        if [[ "$value" =~ [[:space:],] || "$value" =~ ^https?:// ]]; then
            value="\"${value}\""
        fi
        # Quote empty string values
        if [[ -z "$value" ]]; then
            value="\"\""
        fi
        [[ -n "$options" ]] && options="${options},"
        options="${options}${key}=${value}"
    done <<< "$resolved_settings"

    # Add server infrastructure settings from environment config
    local env_config=$(get_game_env_config "palworld" "$env")
    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        local base_name=$(jq -r '.server_infrastructure.base_server_name // "Palworld Server"' "$env_config")
        local instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        local server_name="$base_name"
        [[ -n "$instance_desc" ]] && server_name="${base_name} - ${instance_desc}"
        local admin_password=$(jq -r '.server_infrastructure.admin_password // ""' "$env_config")
        local server_password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        local server_description=$(jq -r '.server_infrastructure.server_description_suffix // ""' "$env_config")
        local max_players=$(jq -r ".instances.\"$instance\".max_players // 32" "$env_config")
        local rcon_enabled=$(jq -r '.network_config.rcon_enabled // false' "$env_config")
        local public_ip=$(jq -r '.network_config.public_ip // ""' "$env_config")

        # Get port assignments for this instance
        local ports=($(get_port_assignments "palworld" "$instance" "$env"))

        options="${options},ServerPlayerMaxNum=${max_players}"
        options="${options},ServerName=\"${server_name}\""
        options="${options},ServerDescription=\"${server_description}\""
        options="${options},AdminPassword=\"${admin_password}\""
        options="${options},ServerPassword=\"${server_password}\""
        options="${options},PublicPort=${ports[0]}"
        options="${options},PublicIP=\"${public_ip}\""
        # Capitalize boolean from JSON
        [[ "$rcon_enabled" == "true" ]] && rcon_enabled="True" || rcon_enabled="False"

        options="${options},RCONEnabled=${rcon_enabled}"
        options="${options},RCONPort=${ports[2]}"
        options="${options},RESTAPIEnabled=True"
        options="${options},RESTAPIPort=${ports[3]}"
    fi

    echo "[/Script/Pal.PalGameWorldSettings]"
    echo "OptionSettings=(${options})"
}

# Inject PalWorldSettings.ini into a Docker volume
# Must be called when the container is NOT running
palworld_inject_settings() {
    local volume_name="$1"
    local preset_file="$2"
    local env="$3"
    local instance="$4"

    log_info "Generating PalWorldSettings.ini from preset..."

    local ini_content
    ini_content=$(palworld_generate_settings_ini "$preset_file" "$env" "$instance")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to generate PalWorldSettings.ini"
        return 1
    fi

    # Write ini to a temp file
    local temp_ini=$(mktemp)
    echo "$ini_content" > "$temp_ini"

    # Use a temp container to write into the volume
    local temp_container="temp-inject-settings-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:/palworld" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container for settings injection"
        rm -f "$temp_ini"
        return 1
    fi

    # Ensure the config directory exists
    docker exec "$temp_container" mkdir -p "/palworld/Pal/Saved/Config/LinuxServer" 2>/dev/null

    # Copy the ini file into the volume
    docker cp "$temp_ini" "$temp_container:/palworld/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"

    local result=$?

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -f "$temp_ini"

    if [[ $result -eq 0 ]]; then
        log_success "PalWorldSettings.ini injected into volume"
    else
        log_error "Failed to inject PalWorldSettings.ini"
    fi

    return $result
}

# Save the active preset name for a given instance
palworld_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"

    echo "$preset" > "${state_dir}/palworld-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

# Get the active preset name for a given instance
palworld_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/palworld-${env}-${instance}.preset"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- Core server operations ---

palworld_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"  # optional
    local preset="$4"  # preset name passed from server-manager

    log_info "Starting Palworld server: $instance (env: $env, preset: $preset)"

    # Get naming
    local container_name=$(get_container_name "palworld" "$instance" "$env")
    local volume_name=$(get_volume_name "palworld" "$instance" "$env")
    local preset_file="${PALWORLD_PRESETS_DIR}/${preset}.json"

    # Validate preset file exists
    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    # Check if server is already running
    if container_running "$container_name"; then
        log_warning "Server already running: $container_name"
        return 1
    fi

    # Get port assignments
    local ports=($(get_port_assignments "palworld" "$instance" "$env"))
    local game_port="${ports[0]}"
    local query_port="${ports[1]}"
    local rcon_port="${ports[2]}"
    local restapi_port="${ports[3]}"

    log_info "Using ports: Game=$game_port, Query=$query_port, RCON=$rcon_port, REST API=$restapi_port"

    # Get server infrastructure settings from environment config
    local env_config=$(get_game_env_config "palworld" "$env")
    local server_name="Palworld-${instance}"
    local admin_password="adminpass123"
    local server_password=""
    local max_players=32
    local restart_policy="unless-stopped"
    local memory_limit="8G"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        local base_name=$(jq -r '.server_infrastructure.base_server_name // "Palworld"' "$env_config")
        local instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        server_name="${base_name} - ${instance_desc}"
        admin_password=$(jq -r '.server_infrastructure.admin_password // "adminpass123"' "$env_config")
        server_password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 32" "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "8g"' "$env_config")
    fi

    # Generate docker-compose file from template
    local compose_file="${REPO_ROOT}/docker-compose-${env}-${instance}.yml"
    local template_file="${PALWORLD_DOCKER_DIR}/docker-compose.template.yml"

    if [[ ! -f "$template_file" ]]; then
        log_error "Docker compose template not found: $template_file"
        return 1
    fi

    # Create context-specific compose file
    log_info "Generating compose file: $compose_file"

    # Use environment variable substitution to generate compose file
    INSTANCE="$instance" \
    GAME_PORT="$game_port" \
    QUERY_PORT="$query_port" \
    RCON_PORT="$rcon_port" \
    RESTAPI_PORT="$restapi_port" \
    VOLUME_NAME="$volume_name" \
    CONTAINER_NAME="$container_name" \
    SERVER_NAME="$server_name" \
    ADMIN_PASSWORD="$admin_password" \
    SERVER_PASSWORD="$server_password" \
    MAX_PLAYERS="$max_players" \
    RESTART_POLICY="$restart_policy" \
    MEMORY_LIMIT="$memory_limit" \
    envsubst < "$template_file" > "$compose_file"

    # Create Docker volume if it doesn't exist
    if ! volume_exists "$volume_name"; then
        log_info "Creating Docker volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi

    # If backup file specified, inject world data BEFORE starting container
    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"

        # Find backup file if not full path
        if [[ ! -f "$backup_file" ]]; then
            local found_backup=""
            for search_path in "${REPO_ROOT}/backups/${instance}/${backup_file}" "${REPO_ROOT}/backups/*/${backup_file}" "$backup_file"; do
                if [[ -f "$search_path" ]]; then
                    found_backup="$search_path"
                    break
                fi
            done

            if [[ -z "$found_backup" ]]; then
                log_error "Backup file not found: $backup_file"
                return 1
            fi
            backup_file="$found_backup"
        fi

        # Restore backup data to volume BEFORE starting container
        if ! palworld_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi

        log_success "World data restored from backup before server start"
    fi

    # Inject PalWorldSettings.ini into the volume before starting
    # (DISABLE_GENERATE_SETTINGS=true in compose prevents the image from overwriting it)
    if ! palworld_inject_settings "$volume_name" "$preset_file" "$env" "$instance"; then
        log_error "Failed to inject game settings into volume"
        return 1
    fi

    # Start server using generated compose file
    log_info "Starting Palworld container: $container_name"
    docker compose -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "Palworld server started: $container_name"

        # Save active preset state
        palworld_save_active_preset "$instance" "$env" "$preset"

        # Wait a bit and show server info
        sleep 5
        echo
        echo "=== Server Information ==="
        echo "  Game: palworld"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Game Port: $game_port"
        echo "  Query Port: $query_port"
        echo "  RCON Port: $rcon_port"
        echo "  REST API Port: $restapi_port"

        if [[ -n "$backup_file" ]]; then
            echo "  Restored from: $(basename "$backup_file")"
        fi

        return 0
    else
        log_error "Failed to start Palworld server: $container_name"
        return 1
    fi
}

palworld_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping Palworld server: $instance (env: $env)"

    local container_name=$(get_container_name "palworld" "$instance" "$env")
    local compose_file="${REPO_ROOT}/docker-compose-${env}-${instance}.yml"

    # Try to use compose file if it exists
    if [[ -f "$compose_file" ]]; then
        log_info "Using compose file: $compose_file"
        docker compose -f "$compose_file" down
    else
        log_info "No compose file found, stopping container directly"
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null
            docker rm "$container_name" 2>/dev/null
        fi
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Palworld server stopped: $container_name"
        return 0
    else
        log_error "Failed to stop Palworld server: $container_name"
        return 1
    fi
}

palworld_restart_server() {
    local instance="$1"
    local env="$2"

    log_info "Restarting Palworld server: $instance (env: $env)"

    local container_name=$(get_container_name "palworld" "$instance" "$env")

    # Check if server is running
    if ! container_running "$container_name"; then
        log_warning "Server not currently running: $instance"
        log_info "Starting server instead..."
        palworld_start_server "$instance" "$env"
        return $?
    fi

    local compose_file="${REPO_ROOT}/docker-compose-${env}-${instance}.yml"

    if [[ -f "$compose_file" ]]; then
        docker compose -f "$compose_file" restart
    else
        docker restart "$container_name"
    fi

    if [[ $? -eq 0 ]]; then
        log_success "Palworld server restarted: $container_name"
        return 0
    else
        log_error "Failed to restart Palworld server: $container_name"
        return 1
    fi
}

palworld_health_check() {
    local context="$1"
    local env="$2"

    local container_name=$(get_container_name "palworld" "$context" "$env")

    # Basic container health check
    if ! container_running "$container_name"; then
        log_error "Palworld server health check failed: container not running"
        return 1
    fi

    # Check if container is healthy
    local container_status=$(docker inspect "$container_name" --format='{{.State.Health.Status}}' 2>/dev/null)
    if [[ "$container_status" == "unhealthy" ]]; then
        log_error "Palworld server health check failed: container unhealthy"
        return 1
    fi

    # Check if ports are listening
    local ports=($(get_port_assignments "palworld" "$context" "$env"))
    local game_port="${ports[0]}"
    local restapi_port="${ports[3]}"

    if ! ss -tuln | grep -q ":$game_port "; then
        log_warning "Game port $game_port not listening"
    fi

    # Try REST API health check if available
    if ss -tuln | grep -q ":$restapi_port "; then
        local env_config=$(get_game_env_config "palworld" "$env")
        local admin_password="adminpass123"
        if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
            admin_password=$(jq -r '.server_infrastructure.admin_password // "adminpass123"' "$env_config")
        fi

        if curl -s -f -u admin:"$admin_password" "http://localhost:${restapi_port}/v1/api/info" >/dev/null 2>&1; then
            log_success "Palworld server health check passed: REST API responsive"
        else
            log_warning "REST API not responsive on port $restapi_port"
        fi
    fi

    log_success "Palworld server health check passed: $context"
    return 0
}

# --- Config swap ---

palworld_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping Palworld config: $instance -> $new_preset (env: $env)"

    local container_name=$(get_container_name "palworld" "$instance" "$env")
    local new_preset_file="${PALWORLD_PRESETS_DIR}/${new_preset}.json"

    # Validate new preset exists and is valid
    if ! palworld_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    # Create emergency backup before swap
    log_info "Creating emergency backup before config swap..."
    create_emergency_backup "config-swap" "palworld" "$instance" "$env"

    # Stop the server
    log_info "Stopping server for config swap..."
    palworld_stop_server "$instance" "$env"

    # Start with the new preset (start_server will inject settings into volume)
    log_info "Starting server with new preset: $new_preset"
    if palworld_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed: $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

palworld_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"  # optional
    local active_preset="$4"  # currently active preset

    log_info "Backing up Palworld data: $instance (env: $env)"

    local volume_name=$(get_volume_name "palworld" "$instance" "$env")

    # Check if volume exists
    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    # Get active preset from state if not provided
    if [[ -z "$active_preset" ]]; then
        active_preset=$(palworld_get_active_preset "$instance" "$env")
    fi

    # Generate backup name if not provided
    if [[ -z "$backup_name" ]]; then
        backup_name="${active_preset:-unknown}_${instance}_${env}_$(date +%Y%m%d_%H%M%S)"
    fi

    local backup_dir="${REPO_ROOT}/backups/${env}/${instance}"
    local backup_file="${backup_dir}/${backup_name}.tar.gz"
    local meta_file="${backup_dir}/${backup_name}.meta.json"

    # Ensure backup directory exists
    mkdir -p "$backup_dir"

    log_info "Creating backup: $(basename "$backup_file")"

    # Check if server is running and trigger save via REST API
    local container_name=$(get_container_name "palworld" "$instance" "$env")
    if container_running "$container_name"; then
        log_info "Server running, triggering save via REST API..."

        # Get REST API port and admin password
        local ports=($(get_port_assignments "palworld" "$instance" "$env"))
        local restapi_port="${ports[3]}"

        # Get admin password from container environment
        local admin_password=$(docker exec "$container_name" printenv ADMIN_PASSWORD 2>/dev/null || echo "adminpass123")

        # Trigger save via REST API
        curl -s -X POST -H "Content-Length: 0" -u admin:"$admin_password" "http://localhost:$restapi_port/v1/api/save" 2>/dev/null

        if [[ $? -eq 0 ]]; then
            log_success "Game save triggered successfully"
            sleep 3
        else
            log_warning "Failed to trigger save via REST API, proceeding with current data"
        fi
    else
        log_info "Server not running, backing up current volume state"
    fi

    # Create temporary container to access volume
    local temp_container="temp-extract-${instance}-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:/palworld" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)

    # Copy only SaveGames and Config (not the entire server installation)
    docker cp "$temp_container:/palworld/Pal/Saved/SaveGames" "$temp_dir/" 2>/dev/null || true
    docker cp "$temp_container:/palworld/Pal/Saved/Config" "$temp_dir/" 2>/dev/null || true

    # Find world ID from GameUserSettings.ini
    local world_id="unknown"
    if [[ -f "$temp_dir/Config/LinuxServer/GameUserSettings.ini" ]]; then
        world_id=$(grep "DedicatedServerName=" "$temp_dir/Config/LinuxServer/GameUserSettings.ini" | tail -1 | cut -d'=' -f2 || echo "unknown")
        if [[ -n "$world_id" ]]; then
            log_success "Found world ID: $world_id"
        fi
    fi

    # Get port assignments for metadata
    local ports=($(get_port_assignments "palworld" "$instance" "$env"))

    # Get infrastructure info from game environment config
    local config=$(get_game_env_config "palworld" "$env")
    local server_name="Unknown"
    local max_players=32

    if [[ -f "$config" ]] && command -v jq >/dev/null 2>&1; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 32" "$config")
    fi

    # Create metadata file
    cat > "$meta_file" << META_EOF
{
    "game": "palworld",
    "instance": "$instance",
    "environment": "$env",
    "world_id": "$world_id",
    "active_preset": "${active_preset:-unknown}",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "infrastructure": {
        "ports": {
            "game": ${ports[0]},
            "query": ${ports[1]},
            "rcon": ${ports[2]},
            "restapi": ${ports[3]}
        },
        "server_name": "$server_name",
        "max_players": $max_players
    },
    "preset_location": "games/palworld/presets/${active_preset:-unknown}.json",
    "volume_name": "$volume_name",
    "container_name": "palworld-${env}-${instance}",
    "backup_method": "docker_volume"
}
META_EOF

    # Create tar archive
    (cd "$temp_dir" && tar -czf "$backup_file" .)

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    if [[ -f "$backup_file" ]]; then
        local backup_size=$(du -sh "$backup_file" | cut -f1)
        log_success "Backup created successfully: $backup_size"
        log_info "Backup file: $backup_file"
        log_info "Metadata file: $meta_file"
        echo "$backup_file"  # Return backup file path
        return 0
    else
        log_error "Failed to create backup archive"
        return 1
    fi
}

palworld_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring Palworld data: $instance from $backup_file (env: $env)"

    # Search for backup file if not a full path
    if [[ ! -f "$backup_file" ]]; then
        local found_backup=""
        for search_path in \
            "${REPO_ROOT}/backups/${env}/${instance}/${backup_file}" \
            "${REPO_ROOT}/backups/${env}/*/${backup_file}" \
            "${REPO_ROOT}/backups/*/${backup_file}"; do
            # Use ls to expand globs
            for match in $search_path; do
                if [[ -f "$match" ]]; then
                    found_backup="$match"
                    break 2
                fi
            done
        done

        if [[ -n "$found_backup" ]]; then
            log_info "Found backup: $found_backup"
            backup_file="$found_backup"
        else
            log_error "Backup file not found: $backup_file"
            return 1
        fi
    fi

    local volume_name=$(get_volume_name "palworld" "$instance" "$env")

    # Extract backup to temp directory
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    # Verify backup has the expected structure
    if [[ ! -d "$temp_dir/SaveGames" ]]; then
        log_error "Backup missing SaveGames/ directory"
        rm -rf "$temp_dir"
        return 1
    fi

    # Create temporary container to access volume
    local temp_container="temp-restore-${instance}-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:/palworld" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    # Nuke existing SaveGames and Config, then replace with backup contents
    log_info "Clearing existing SaveGames and Config..."
    docker exec "$temp_container" sh -c "rm -rf /palworld/Pal/Saved/SaveGames" 2>/dev/null || true
    docker exec "$temp_container" sh -c "rm -rf /palworld/Pal/Saved/Config" 2>/dev/null || true

    log_info "Restoring SaveGames from backup..."
    docker cp "$temp_dir/SaveGames" "$temp_container:/palworld/Pal/Saved/"

    if [[ -d "$temp_dir/Config" ]]; then
        log_info "Restoring Config from backup..."
        docker cp "$temp_dir/Config" "$temp_container:/palworld/Pal/Saved/"
    fi

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "Palworld world restoration completed successfully"
    log_info "Volume: $volume_name"

    return 0
}

# --- Utilities ---

palworld_get_ports() {
    local context="$1"
    local env="$2"

    # Return actual ports used by Palworld
    get_port_assignments "palworld" "$context" "$env"
}

palworld_validate_preset() {
    local preset_file="$1"
    local context="$2"
    local env="$3"

    log_info "Validating Palworld preset: $preset_file"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required for preset validation"
        return 1
    fi

    # Validate JSON syntax
    if ! jq empty "$preset_file" 2>/dev/null; then
        log_error "Preset file is not valid JSON: $preset_file"
        return 1
    fi

    # Check required sections
    if ! jq -e '.game_settings' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'game_settings' section: $preset_file"
        return 1
    fi

    if ! jq -e '.metadata.name' "$preset_file" >/dev/null 2>&1; then
        log_warning "Preset missing 'metadata.name': $preset_file"
    fi

    # Validate parent preset exists if inherits is set
    local inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")
    if [[ -n "$inherits" ]]; then
        local parent_file="${PALWORLD_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "Palworld preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f palworld_start_server palworld_stop_server palworld_restart_server
export -f palworld_health_check palworld_config_swap
export -f palworld_backup_data palworld_restore_data
export -f palworld_get_ports palworld_validate_preset
export -f palworld_resolve_preset palworld_generate_settings_ini palworld_inject_settings
export -f palworld_save_active_preset palworld_get_active_preset
