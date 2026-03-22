#!/bin/bash

# Palworld Game Plugin - Game-specific server management functions
# Implements the existing palworld-docker functionality in the new plugin architecture

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${REPO_ROOT}/scripts/shared/server-utils.sh"

# Palworld-specific paths and configuration
PALWORLD_DOCKER_DIR="${REPO_ROOT}/docker/palworld"

# Required plugin functions for palworld

palworld_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"  # optional
    local preset="$4"  # preset name passed from server-manager
    
    log_info "Starting Palworld server: $instance (env: $env, preset: $preset)"
    
    # Get naming
    local container_name=$(get_container_name "palworld" "$instance" "$env")
    local volume_name=$(get_volume_name "palworld" "$instance" "$env")
    local preset_file="${REPO_ROOT}/games/palworld/presets/${preset}.json"
    
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
    PRESET="$preset" \
    GAME_PORT="$game_port" \
    QUERY_PORT="$query_port" \
    RCON_PORT="$rcon_port" \
    RESTAPI_PORT="$restapi_port" \
    VOLUME_NAME="$volume_name" \
    CONTAINER_NAME="$container_name" \
    PRESET_FILE="$preset_file" \
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
    
    # Start server using generated compose file
    log_info "Starting Palworld container: $container_name"
    docker compose -f "$compose_file" up -d
    
    if [[ $? -eq 0 ]]; then
        log_success "Palworld server started: $container_name"
        
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
        echo "  Config: $preset_file"
        
        if [[ -n "$backup_file" ]]; then
            echo "  Restored from: $(basename "$backup_file")"
        fi
        
        return 0
    else
        log_error "Failed to start Palworld server: $context"
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
        
        # Optionally remove compose file
        if [[ "$env" != "production" ]]; then
            rm -f "$compose_file"
            log_info "Removed compose file: $compose_file"
        fi
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
        if curl -s -f -u admin:ilovepasswords "http://localhost:${restapi_port}/v1/api/info" >/dev/null 2>&1; then
            log_success "Palworld server health check passed: REST API responsive"
        else
            log_warning "REST API not responsive on port $restapi_port"
        fi
    fi
    
    log_success "Palworld server health check passed: $context"
    return 0
}

palworld_config_swap() {
    local context="$1"
    local env="$2"
    local new_preset="$3"
    
    log_info "Swapping Palworld config: $context -> $new_preset (env: $env)"
    
    local container_name=$(get_container_name "palworld" "$context" "$env")
    local current_preset_file="${REPO_ROOT}/environments/${env}/games/palworld/presets/${context}.env"
    local new_preset_file="${REPO_ROOT}/environments/${env}/games/palworld/presets/${new_preset}.env"
    
    # Validate new preset exists
    if [[ ! -f "$new_preset_file" ]]; then
        log_error "New preset file not found: $new_preset_file"
        return 1
    fi
    
    # Validate the preset
    if ! palworld_validate_preset "$new_preset_file" "$context" "$env"; then
        return 1
    fi
    
    # Check if container is running
    if ! container_running "$container_name"; then
        log_error "Container not running: $container_name"
        return 1
    fi
    
    # Create backup of current preset
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_preset="${current_preset_file}.backup-${timestamp}"
    cp "$current_preset_file" "$backup_preset"
    log_info "Backed up current preset: $backup_preset"
    
    # Stop server
    log_info "Stopping server for config swap..."
    palworld_stop_server "$context" "$env"
    
    # Update preset file
    log_info "Updating preset configuration..."
    cp "$new_preset_file" "$current_preset_file"
    
    # Start server with new configuration
    log_info "Starting server with new configuration..."
    if palworld_start_server "$context" "$env"; then
        log_success "Config swap completed successfully!"
        log_info "Active preset: $new_preset"
        log_info "Backup created: $backup_preset"
        return 0
    else
        log_error "Failed to start server with new configuration"
        # Restore original preset
        log_info "Restoring original preset..."
        cp "$backup_preset" "$current_preset_file"
        palworld_start_server "$context" "$env"
        return 1
    fi
}

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
        local save_response=$(curl -s -X POST -H "Content-Length: 0" -u admin:"$admin_password" "http://localhost:$restapi_port/v1/api/save" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            log_success "Game save triggered successfully"
            # Wait a few seconds for save to complete
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
    
    # Copy data from volume
    docker cp "$temp_container:/palworld/Pal/Saved/." "$temp_dir/"
    
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
    
    # Get infrastructure info
    local infra_file="${REPO_ROOT}/environments/${env}/infrastructure.json"
    local server_name="Unknown"
    local max_players=32
    
    if [[ -f "$infra_file" ]] && command -v jq >/dev/null 2>&1; then
        server_name=$(jq -r ".instance_mappings.\"$instance\".display_name // \"Unknown\"" "$infra_file")
        max_players=$(jq -r ".instance_mappings.\"$instance\".max_players // 32" "$infra_file")
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
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    local volume_name=$(get_volume_name "palworld" "$instance" "$env")
    
    # Extract backup to identify target world ID
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Find the world ID from the backup
    local backup_world_id=""
    if [[ -f "$temp_dir/Config/LinuxServer/GameUserSettings.ini" ]]; then
        backup_world_id=$(grep "DedicatedServerName=" "$temp_dir/Config/LinuxServer/GameUserSettings.ini" | head -1 | cut -d'=' -f2)
        log_info "Target world ID from backup: $backup_world_id"
    fi
    
    if [[ -z "$backup_world_id" ]]; then
        # Try to detect from SaveGames structure
        local world_dirs=($(find "$temp_dir/SaveGames/0/" -maxdepth 1 -type d -name "[A-F0-9]*" 2>/dev/null))
        if [[ ${#world_dirs[@]} -gt 0 ]]; then
            # Use the most recent world directory
            backup_world_id=$(basename "${world_dirs[0]}")
            log_info "Detected world ID from SaveGames: $backup_world_id"
        fi
    fi
    
    if [[ -z "$backup_world_id" ]]; then
        log_error "Could not determine world ID from backup"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Create temporary container to access and modify volume
    local temp_container="temp-restore-${instance}-$$"
    
    docker run -d --name "$temp_container" \
        -v "$volume_name:/palworld" \
        ubuntu:22.04 sleep 300 >/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_info "Clearing existing data and restoring backup..."
    
    # Completely clear existing world and config data
    docker exec "$temp_container" sh -c "rm -rf /palworld/Pal/Saved/SaveGames/0/*" 2>/dev/null || true
    docker exec "$temp_container" sh -c "rm -rf /palworld/Pal/Saved/Config/*" 2>/dev/null || true
    
    # Ensure directory structure exists
    docker exec "$temp_container" mkdir -p "/palworld/Pal/Saved/SaveGames/0" 2>/dev/null
    docker exec "$temp_container" mkdir -p "/palworld/Pal/Saved/Config/LinuxServer" 2>/dev/null
    
    # Copy all backup data into volume
    log_info "Restoring SaveGames..."
    if [[ -d "$temp_dir/SaveGames" ]]; then
        docker cp "$temp_dir/SaveGames/." "$temp_container:/palworld/Pal/Saved/SaveGames/"
    fi
    
    log_info "Restoring Config..."
    if [[ -d "$temp_dir/Config" ]]; then
        docker cp "$temp_dir/Config/." "$temp_container:/palworld/Pal/Saved/Config/"
    fi
    
    # Verify restoration succeeded
    local restored_world_id=$(docker exec "$temp_container" grep "DedicatedServerName=" "/palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini" 2>/dev/null | head -1 | cut -d'=' -f2)
    
    if [[ "$restored_world_id" != "$backup_world_id" ]]; then
        log_error "World ID verification failed. Expected: $backup_world_id, Found: $restored_world_id"
        docker rm -f "$temp_container" >/dev/null 2>&1
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Verify world directory exists
    if ! docker exec "$temp_container" test -d "/palworld/Pal/Saved/SaveGames/0/$backup_world_id" 2>/dev/null; then
        log_error "World directory missing after restore: $backup_world_id"
        docker rm -f "$temp_container" >/dev/null 2>&1
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"
    
    log_success "Palworld world restoration completed successfully"
    log_info "Restored world: $backup_world_id"
    log_info "Volume: $volume_name"
    
    return 0
}

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
    
    # Source the preset to validate syntax
    if ! source "$preset_file" 2>/dev/null; then
        log_error "Preset file has syntax errors: $preset_file"
        return 1
    fi
    
    # Check for required variables (basic validation)
    local required_vars=("SERVER_NAME")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log_warning "Required variable not set in preset: $var"
        fi
    done
    
    log_success "Palworld preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f palworld_start_server palworld_stop_server palworld_restart_server
export -f palworld_health_check palworld_config_swap
export -f palworld_backup_data palworld_restore_data
export -f palworld_get_ports palworld_validate_preset