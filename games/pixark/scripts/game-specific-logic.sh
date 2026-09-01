#!/bin/bash

# PixARK Game Plugin - Game-specific server management functions
# Uses the upstream silentmecha/pixark-linux image, which ships a server +
# SFTP sidecar for remote file access. Config flows entirely through
# environment variables; PixARK (Unreal-based) additionally accepts a string
# of ?Arg=Value URL-style CLI args via ADDITIONAL_ARGS.
#
# PixARK is port-remap-hostile, and worse: under a Docker bridge network it
# advertises its container-internal address to clients for the voxel terrain
# session, so players connect and spawn but never receive any terrain. The
# container therefore runs with host networking (see the comment at the top of
# docker-compose.template.yml). The offset-shifted ports below are still what
# the server binds to directly — the per-instance offset model is what keeps
# instances from colliding now that there is no network namespace between them.

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
    source "${REPO_ROOT}/scripts/shared/server-utils.sh"
fi

PIXARK_DOCKER_DIR="${REPO_ROOT}/games/pixark/docker"
PIXARK_PRESETS_DIR="${REPO_ROOT}/games/pixark/presets"
PIXARK_VOLUME_MOUNT="/home/steam/PixARK-dedicated/ShooterGame/Saved"
PIXARK_IMAGE_TAG="pixark-server:latest"

# --- Image build ---
#
# Upstream silentmecha/pixark-linux ships with a wine64 reference in entry.sh
# that breaks against modern Wine (wine 9+ no longer ships wine64 as a
# separate binary). games/pixark/docker/Dockerfile derives from upstream
# and adds a wine64 -> wine symlink. docker build uses its layer cache so
# rebuilds on unchanged Dockerfile are no-ops.

pixark_build_image() {
    log_info "Building ${PIXARK_IMAGE_TAG} from ${PIXARK_DOCKER_DIR}"
    if ! docker build -t "$PIXARK_IMAGE_TAG" "$PIXARK_DOCKER_DIR"; then
        log_error "Failed to build ${PIXARK_IMAGE_TAG}"
        return 1
    fi
    log_success "${PIXARK_IMAGE_TAG} built"
    return 0
}

# --- Preset resolution ---

pixark_resolve_preset() {
    local preset_file="$1"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${PIXARK_PRESETS_DIR}/${inherits}"
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

pixark_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"
    echo "$preset" > "${state_dir}/pixark-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

pixark_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/pixark-${env}-${instance}.preset"
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- RCON helper ---

# Best-effort RCON command. If the container doesn't ship rcon-cli,
# the exec simply fails and we swallow the error — caller should tolerate.
pixark_rcon_command() {
    local instance="$1"
    local env="$2"
    local command="$3"

    local container_name
    container_name=$(get_container_name "pixark" "$instance" "$env")

    if ! container_running "$container_name"; then
        return 1
    fi

    docker exec "$container_name" rcon-cli "$command" 2>/dev/null
}

# --- Core server operations ---

pixark_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"
    local preset="$4"

    log_info "Starting PixARK server: $instance (env: $env, preset: $preset)"

    local container_name
    container_name=$(get_container_name "pixark" "$instance" "$env")
    local volume_name
    volume_name=$(get_volume_name "pixark" "$instance" "$env")
    local preset_file="${PIXARK_PRESETS_DIR}/${preset}.json"

    if [[ ! -f "$preset_file" ]]; then
        log_error "Preset file not found: $preset_file"
        return 1
    fi

    if container_running "$container_name"; then
        log_warning "Server already running: $container_name"
        return 1
    fi

    local ports
    ports=($(get_port_assignments "pixark" "$instance" "$env"))
    local game_port="${ports[0]}"
    local query_port="${ports[1]}"
    local rcon_port="${ports[2]}"
    local cube_port="${ports[3]}"

    log_info "Using ports: Game=${game_port}/udp Query=${query_port}/udp RCON=${rcon_port}/tcp Cube=${cube_port}/tcp"

    local resolved
    resolved=$(pixark_resolve_preset "$preset_file") || return 1

    local additional_args
    additional_args=$(echo "$resolved" | jq -r '.game_settings.additional_args // ""')

    # Infrastructure + per-instance from env config
    local env_config
    env_config=$(get_game_env_config "pixark" "$env")
    local base_name="PixARK Server"
    local instance_desc="$instance"
    local admin_password
    admin_password=$(get_secret "pixark" "$env" "admin_password") || return 1
    local server_password
    server_password=$(get_secret "pixark" "$env" "base_password") || return 1
    local sft_user="pixark"
    local sft_pass
    sft_pass=$(get_secret "pixark" "$env" "sft_pass") || return 1
    local sft_port_base=2222
    local rcon_enabled_raw="true"
    local restart_policy="unless-stopped"
    local memory_limit="8g"
    local map="CubeWorld_Light"
    local cube_world="cubeworld"
    local map_seed=""
    local alt_save_dir=""
    local cluster_id=""
    local max_players=8
    local port_offset=0
    local update_on_start="true"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        base_name=$(jq -r '.server_infrastructure.base_server_name // "PixARK Server"' "$env_config")
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        sft_user=$(jq -r '.server_infrastructure.sft_user // "pixark"' "$env_config")
        sft_port_base=$(jq -r '.server_infrastructure.sft_port_base // 2222' "$env_config")
        rcon_enabled_raw=$(jq -r '.network_config.rcon_enabled // true' "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "8g"' "$env_config")
        map=$(jq -r ".instances.\"$instance\".map // \"CubeWorld_Light\"" "$env_config")
        cube_world=$(jq -r ".instances.\"$instance\".cube_world // \"cubeworld\"" "$env_config")
        map_seed=$(jq -r ".instances.\"$instance\".map_seed // \"\"" "$env_config")
        alt_save_dir=$(jq -r ".instances.\"$instance\".alt_save_dir // \"\"" "$env_config")
        cluster_id=$(jq -r ".instances.\"$instance\".cluster_id // \"\"" "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 8" "$env_config")
        port_offset=$(jq -r ".instances.\"$instance\".port_offset // 0" "$env_config")
        local update_raw
        update_raw=$(jq -r '.game.update_on_boot // true' "$env_config")
        [[ "$update_raw" == "true" ]] && update_on_start="true" || update_on_start="false"
    fi

    # Install volume is shared across instances in the same env (mirrors ARK's server_files pattern)
    local install_volume_name="pixark-install-${env}"

    local rcon_enabled="True"
    [[ "$rcon_enabled_raw" == "false" ]] && rcon_enabled="False"

    local session_name="${base_name} - ${instance_desc}"

    # SFTP port: base + (port_offset * 10) to avoid collisions across instances
    local sft_port=$((sft_port_base + port_offset * 10))

    # Generate docker-compose file
    local compose_file="${REPO_ROOT}/docker-compose-pixark-${env}-${instance}.yml"
    local template_file="${PIXARK_DOCKER_DIR}/docker-compose.template.yml"

    if [[ ! -f "$template_file" ]]; then
        log_error "Docker compose template not found: $template_file"
        return 1
    fi

    if ! pixark_build_image; then
        return 1
    fi

    log_info "Generating compose file: $compose_file"
    log_info "SFTP port: $sft_port (base=$sft_port_base, offset=$port_offset)"

    # Wine 11 uses the kernel's ntsync sync primitives when /dev/ntsync exists,
    # which is a large win for a heavily threaded UE4 server. Map the device
    # only when the host actually has it (kernel 6.14+) — naming a device that
    # does not exist is a hard container-start failure, and the server runs
    # fine on the futex fallback without it.
    local ntsync_block=""
    if [[ -c /dev/ntsync ]]; then
        ntsync_block=$'    devices:\n      - /dev/ntsync:/dev/ntsync'
        log_info "Host provides /dev/ntsync — enabling Wine ntsync fast path"
    else
        log_info "No /dev/ntsync on host — Wine will use the futex fallback"
    fi

    NTSYNC_BLOCK="$ntsync_block" \
    CONTAINER_NAME="$container_name" \
    VOLUME_NAME="$volume_name" \
    INSTALL_VOLUME_NAME="$install_volume_name" \
    UPDATE_ON_START="$update_on_start" \
    GAME_PORT="$game_port" \
    QUERY_PORT="$query_port" \
    RCON_PORT="$rcon_port" \
    CUBE_PORT="$cube_port" \
    RESTART_POLICY="$restart_policy" \
    MEMORY_LIMIT="$memory_limit" \
    MAP="$map" \
    SESSION_NAME="$session_name" \
    SERVER_PASSWORD="$server_password" \
    ADMIN_PASSWORD="$admin_password" \
    MAX_PLAYERS="$max_players" \
    RCON_ENABLED="$rcon_enabled" \
    CULTURE="en" \
    CUBE_WORLD="$cube_world" \
    MAP_SEED="$map_seed" \
    CLUSTER_ID="$cluster_id" \
    ALT_SAVE_DIR="$alt_save_dir" \
    ADDITIONAL_ARGS="$additional_args" \
    SFT_USER="$sft_user" \
    SFT_PASS="$sft_pass" \
    SFT_PORT="$sft_port" \
    envsubst < "$template_file" > "$compose_file"

    # Shared install volume (one per env, reused across instances)
    if ! volume_exists "$install_volume_name"; then
        log_info "Creating shared install volume: $install_volume_name"
        docker volume create "$install_volume_name" >/dev/null
    fi
    if ! volume_exists "$volume_name"; then
        log_info "Creating save data volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi

    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"
        if ! pixark_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi
        log_success "World data restored from backup before server start"
    fi

    log_info "Starting PixARK container: $container_name"
    docker compose -p "$container_name" -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "PixARK server started: $container_name"
        pixark_save_active_preset "$instance" "$env" "$preset"

        sleep 3
        echo
        echo "=== Server Information ==="
        echo "  Game: pixark"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Map: $map"
        echo "  Session: $session_name"
        echo "  Game Port: $game_port/udp"
        echo "  Query Port: $query_port/udp"
        echo "  RCON Port: $rcon_port/tcp"
        echo "  Cube Port: $cube_port/tcp"
        echo "  SFTP Port: $sft_port (user=$sft_user)"
        echo
        echo "  Note: first start may take several minutes to initialize the world."
        return 0
    else
        log_error "Failed to start PixARK server: $container_name"
        return 1
    fi
}

pixark_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping PixARK server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "pixark" "$instance" "$env")
    local sftp_container="${container_name}-sftp"
    local compose_file="${REPO_ROOT}/docker-compose-pixark-${env}-${instance}.yml"

    # Save world via RCON before stopping (best-effort)
    if container_running "$container_name"; then
        log_info "Sending saveworld via RCON..."
        pixark_rcon_command "$instance" "$env" "saveworld" 2>/dev/null || true
        sleep 3
    fi

    if [[ -f "$compose_file" ]]; then
        docker compose -p "$container_name" -f "$compose_file" down
    else
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null
            docker rm "$container_name" 2>/dev/null
        fi
    fi

    # Clean up the SFTP sidecar if still present (mirrors ark's config-sidecar cleanup)
    if container_exists "$sftp_container"; then
        log_info "Stopping SFTP sidecar: $sftp_container"
        docker stop "$sftp_container" 2>/dev/null || true
        docker rm "$sftp_container" 2>/dev/null || true
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

    log_success "PixARK server stopped: $container_name"
    return 0
}

pixark_health_check() {
    local instance="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "pixark" "$instance" "$env")

    if ! container_running "$container_name"; then
        log_error "PixARK server health check failed: container not running"
        return 1
    fi

    local health_status
    health_status=$(docker inspect "$container_name" --format='{{.State.Health.Status}}' 2>/dev/null)

    case "$health_status" in
        healthy)
            log_success "PixARK server health check passed: $instance (healthy)"
            return 0
            ;;
        unhealthy)
            log_error "PixARK server health check failed: $instance (unhealthy)"
            return 1
            ;;
        starting)
            log_info "PixARK server still starting: $instance"
            return 0
            ;;
        *)
            log_success "PixARK server health check passed: $instance (running)"
            return 0
            ;;
    esac
}

# --- Config swap ---

pixark_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping PixARK config: $instance -> $new_preset (env: $env)"

    local new_preset_file="${PIXARK_PRESETS_DIR}/${new_preset}.json"

    if ! pixark_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    log_info "Creating pre-swap emergency backup..."
    create_emergency_backup "config-swap" "pixark" "$instance" "$env" >/dev/null || true

    log_info "Stopping server for config swap..."
    pixark_stop_server "$instance" "$env"

    log_info "Starting server with new preset: $new_preset"
    if pixark_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed: $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

pixark_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"
    local active_preset="$4"

    log_info "Backing up PixARK data: $instance (env: $env)"

    local volume_name
    volume_name=$(get_volume_name "pixark" "$instance" "$env")

    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    if [[ -z "$active_preset" ]]; then
        active_preset=$(pixark_get_active_preset "$instance" "$env")
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
    container_name=$(get_container_name "pixark" "$instance" "$env")
    if container_running "$container_name"; then
        log_info "Server running, triggering saveworld via RCON..."
        pixark_rcon_command "$instance" "$env" "saveworld" 2>/dev/null || true
        sleep 3
    fi

    local temp_container="temp-pixark-extract-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:${PIXARK_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    local temp_dir
    temp_dir=$(mktemp -d)
    docker cp "${temp_container}:${PIXARK_VOLUME_MOUNT}/." "${temp_dir}/" 2>/dev/null || true

    docker rm -f "$temp_container" >/dev/null 2>&1

    local ports
    ports=($(get_port_assignments "pixark" "$instance" "$env"))
    local env_config
    env_config=$(get_game_env_config "pixark" "$env")
    local server_name="Unknown"
    local max_players=8
    local map_name="Unknown"
    if [[ -f "$env_config" ]]; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 8" "$env_config")
        map_name=$(jq -r ".instances.\"$instance\".map // \"Unknown\"" "$env_config")
    fi

    cat > "$meta_file" << META_EOF
{
    "game": "pixark",
    "instance": "$instance",
    "environment": "$env",
    "active_preset": "${active_preset:-unknown}",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "infrastructure": {
        "ports": {
            "game": ${ports[0]},
            "query": ${ports[1]},
            "rcon": ${ports[2]},
            "cube": ${ports[3]}
        },
        "server_name": "$server_name",
        "map": "$map_name",
        "max_players": $max_players
    },
    "volume_name": "$volume_name",
    "container_name": "pixark-${env}-${instance}",
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

pixark_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring PixARK data: $instance from $backup_file (env: $env)"

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
    container_name=$(get_container_name "pixark" "$instance" "$env")
    if container_running "$container_name"; then
        log_error "Cannot restore while server is running. Stop the server first."
        return 1
    fi

    local volume_name
    volume_name=$(get_volume_name "pixark" "$instance" "$env")

    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    local temp_container="temp-pixark-restore-${instance}-$$"
    docker run -d --name "$temp_container" \
        -v "${volume_name}:${PIXARK_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    log_info "Clearing existing Saved contents in volume..."
    docker exec "$temp_container" sh -c "rm -rf ${PIXARK_VOLUME_MOUNT:?}/*" 2>/dev/null || true

    log_info "Restoring Saved contents from backup..."
    docker cp "${temp_dir}/." "${temp_container}:${PIXARK_VOLUME_MOUNT}/"

    docker exec "$temp_container" chown -R 1000:1000 "$PIXARK_VOLUME_MOUNT" 2>/dev/null

    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "PixARK restore completed"
    return 0
}

# --- Utilities ---

pixark_get_ports() {
    local instance="$1"
    local env="$2"
    get_port_assignments "pixark" "$instance" "$env"
}

pixark_validate_preset() {
    local preset_file="$1"
    local instance="$2"
    local env="$3"

    log_info "Validating PixARK preset: $preset_file"

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
        local parent_file="${PIXARK_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "PixARK preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f pixark_start_server pixark_stop_server
export -f pixark_health_check pixark_config_swap
export -f pixark_backup_data pixark_restore_data
export -f pixark_get_ports pixark_validate_preset
export -f pixark_resolve_preset pixark_rcon_command pixark_build_image
export -f pixark_save_active_preset pixark_get_active_preset
