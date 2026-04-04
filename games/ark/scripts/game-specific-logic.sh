#!/bin/bash

# ARK Survival Ascended Game Plugin - Game-specific server management functions
# Implements the plugin interface for ARK SA server management
#
# ARK uses two config files: GameUserSettings.ini and Game.ini
# Both live in ShooterGame/Saved/Config/WindowsServer/ inside the volume
# ARK has no REST API; admin commands go through RCON

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
    source "${REPO_ROOT}/scripts/shared/server-utils.sh"
fi

# ARK-specific paths and configuration
ARK_DOCKER_DIR="${REPO_ROOT}/games/ark/docker"
ARK_PRESETS_DIR="${REPO_ROOT}/games/ark/presets"

# Volume mounts at ShooterGame/Saved, so config path is relative to volume root
ARK_VOLUME_MOUNT="/saved"
ARK_CONFIG_SUBPATH="Config/WindowsServer"

# Settings that ARK's dynamic config can apply live without restart.
# These can appear in GameUserSettings.ini [ServerSettings] for dynamic config,
# even if the preset stores some of them under Game.ini sections.
ARK_HOT_SWAPPABLE_SETTINGS=(
    "XPMultiplier" "TamingSpeedMultiplier" "HarvestAmountMultiplier" "HarvestHealthMultiplier"
    "PlayerCharacterWaterDrainMultiplier" "PlayerCharacterFoodDrainMultiplier"
    "PlayerCharacterStaminaDrainMultiplier" "PlayerCharacterHealthRecoveryMultiplier"
    "DinoCharacterFoodDrainMultiplier" "DinoCharacterStaminaDrainMultiplier"
    "DinoCharacterHealthRecoveryMultiplier" "DamageTakenMultiplier"
    "DinoDamageMultiplier" "PlayerDamageMultiplier" "StructureDamageMultiplier"
    "StructureResistanceMultiplier" "ResourcesRespawnPeriodMultiplier"
    "NightTimeSpeedScale" "DayTimeSpeedScale" "ItemStackSizeMultiplier"
    "MaxPersonalTamedDinos" "MaxTamedDinos" "AutoSavePeriodMinutes"
    "MatingIntervalMultiplier" "EggHatchSpeedMultiplier" "BabyMatureSpeedMultiplier"
    "BabyCuddleIntervalMultiplier" "BabyImprintAmountMultiplier"
    "BabyFoodConsumptionSpeedMultiplier" "CropGrowthSpeedMultiplier"
    "CraftXPMultiplier" "GenericXPMultiplier" "HarvestXPMultiplier"
    "KillXPMultiplier" "SpecialXPMultiplier" "HexagonRewardMultiplier"
    "LayEggIntervalMultiplier"
)

# --- Preset resolution ---

# Resolve a preset JSON file with inheritance, outputting merged game_settings as JSON
# ARK presets have nested structure: game_settings.GameUserSettings.Section.Key and game_settings.Game.Section.Key
ark_resolve_preset() {
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
    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")

    if [[ -n "$inherits" ]]; then
        local parent_file="${ARK_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file (inherited by $(basename "$preset_file"))"
            return 1
        fi

        # Deep merge: parent game_settings * child game_settings (child overrides parent)
        jq -s '.[0].game_settings * .[1].game_settings' "$parent_file" "$preset_file"
    else
        # No inheritance, just output this preset's game_settings
        jq '.game_settings' "$preset_file"
    fi
}

# Generate GameUserSettings.ini content from a resolved preset + server infrastructure
ark_generate_game_user_settings_ini() {
    local preset_file="$1"
    local env="$2"
    local instance="$3"

    local resolved_settings
    resolved_settings=$(ark_resolve_preset "$preset_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Get the GameUserSettings portion
    local gus_settings
    gus_settings=$(echo "$resolved_settings" | jq '.GameUserSettings')

    if [[ "$gus_settings" == "null" ]]; then
        log_error "Preset missing GameUserSettings section"
        return 1
    fi

    # Get server infrastructure from environment config
    local env_config
    env_config=$(get_game_env_config "ark" "$env")

    local server_name="ARK Server"
    local admin_password=""
    local server_password=""
    local max_players=70
    local rcon_enabled="true"
    local ports
    ports=($(get_port_assignments "ark" "$instance" "$env"))
    local rcon_port="${ports[2]}"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        local base_name
        base_name=$(jq -r '.server_infrastructure.base_server_name // "ARK Server"' "$env_config")
        local instance_desc
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        server_name="${base_name} - ${instance_desc}"
        admin_password=$(jq -r '.server_infrastructure.admin_password // ""' "$env_config")
        server_password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 70" "$env_config")
        rcon_enabled=$(jq -r '.network_config.rcon_enabled // true' "$env_config")
    fi

    # Iterate over each section in GameUserSettings and output [Section]\nKey=Value
    local sections
    sections=$(echo "$gus_settings" | jq -r 'keys[]')

    while IFS= read -r section; do
        [[ -z "$section" ]] && continue
        echo "[$section]"

        # Keys that will be injected from infrastructure (skip from preset to avoid duplicates)
        local skip_keys=""
        if [[ "$section" == "ServerSettings" ]]; then
            skip_keys="ServerAdminPassword|ServerPassword|MaxPlayers|RCONPort|RCONEnabled"
        elif [[ "$section" == "SessionSettings" ]]; then
            skip_keys="SessionName"
        fi

        # Output each key=value in this section
        # Use process substitution to avoid subshell losing output
        while IFS='=' read -r key value; do
            # Skip keys that will be injected from infrastructure
            if [[ -n "$skip_keys" ]] && echo "$key" | grep -qE "^(${skip_keys})$"; then
                continue
            fi
            # Convert JSON booleans: true->True, false->False for ARK ini
            if [[ "$value" == "true" ]]; then
                value="True"
            elif [[ "$value" == "false" ]]; then
                value="False"
            fi
            echo "${key}=${value}"
        done < <(echo "$gus_settings" | jq -r --arg sec "$section" \
            '.[$sec] | to_entries[] | "\(.key)=\(.value)"')

        # Inject server infrastructure into ServerSettings section
        if [[ "$section" == "ServerSettings" ]]; then
            echo "ServerAdminPassword=${admin_password}"
            echo "ServerPassword=${server_password}"
            echo "MaxPlayers=${max_players}"
            echo "RCONPort=${rcon_port}"
            if [[ "$rcon_enabled" == "true" ]]; then
                echo "RCONEnabled=True"
            else
                echo "RCONEnabled=False"
            fi
        fi

        # Inject session name into SessionSettings section
        if [[ "$section" == "SessionSettings" ]]; then
            echo "SessionName=${server_name}"
        fi

        echo ""
    done <<< "$sections"
}

# Generate Game.ini content from a resolved preset
ark_generate_game_ini() {
    local preset_file="$1"
    local env="$2"
    local instance="$3"

    local resolved_settings
    resolved_settings=$(ark_resolve_preset "$preset_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    # Get the Game portion
    local game_settings
    game_settings=$(echo "$resolved_settings" | jq '.Game')

    if [[ "$game_settings" == "null" ]]; then
        log_error "Preset missing Game section"
        return 1
    fi

    # Iterate over each section in Game and output [Section]\nKey=Value
    local sections
    sections=$(echo "$game_settings" | jq -r 'keys[]')

    while IFS= read -r section; do
        [[ -z "$section" ]] && continue
        echo "[$section]"

        while IFS='=' read -r key value; do
            if [[ "$value" == "true" ]]; then
                value="True"
            elif [[ "$value" == "false" ]]; then
                value="False"
            fi
            echo "${key}=${value}"
        done < <(echo "$game_settings" | jq -r --arg sec "$section" \
            '.[$sec] | to_entries[] | "\(.key)=\(.value)"')

        echo ""
    done <<< "$sections"
}

# Inject both GameUserSettings.ini and Game.ini into a Docker volume
# Must be called when the container is NOT running
ark_inject_settings() {
    local volume_name="$1"
    local preset_file="$2"
    local env="$3"
    local instance="$4"

    log_info "Generating ARK config files from preset..."

    local config_path="${ARK_VOLUME_MOUNT}/${ARK_CONFIG_SUBPATH}"

    # Generate GameUserSettings.ini
    local gus_content
    gus_content=$(ark_generate_game_user_settings_ini "$preset_file" "$env" "$instance")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to generate GameUserSettings.ini"
        return 1
    fi

    # Generate Game.ini
    local game_content
    game_content=$(ark_generate_game_ini "$preset_file" "$env" "$instance")
    if [[ $? -ne 0 ]]; then
        log_error "Failed to generate Game.ini"
        return 1
    fi

    # Write ini files to temp files
    local temp_gus
    temp_gus=$(mktemp)
    echo "$gus_content" > "$temp_gus"

    local temp_game
    temp_game=$(mktemp)
    echo "$game_content" > "$temp_game"

    # Use a temp container to write into the volume
    local temp_container="temp-ark-inject-settings-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:${ARK_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container for settings injection"
        rm -f "$temp_gus" "$temp_game"
        return 1
    fi

    # Ensure the config and logs directories exist, and fix ownership for ark user (UID 7777)
    docker exec "$temp_container" mkdir -p "$config_path" 2>/dev/null
    docker exec "$temp_container" mkdir -p "${ARK_VOLUME_MOUNT}/Logs" 2>/dev/null
    docker exec "$temp_container" chown -R 7777:7777 "${ARK_VOLUME_MOUNT}" 2>/dev/null

    # Copy both ini files into the volume
    docker cp "$temp_gus" "$temp_container:${config_path}/GameUserSettings.ini"
    local result_gus=$?

    docker cp "$temp_game" "$temp_container:${config_path}/Game.ini"
    local result_game=$?

    # Fix ownership after copy (docker cp creates files as root)
    docker exec "$temp_container" chown -R 7777:7777 "${ARK_VOLUME_MOUNT}" 2>/dev/null

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -f "$temp_gus" "$temp_game"

    if [[ $result_gus -eq 0 && $result_game -eq 0 ]]; then
        log_success "GameUserSettings.ini and Game.ini injected into volume"
        return 0
    else
        log_error "Failed to inject config files into volume"
        return 1
    fi
}

# --- Dynamic config (hot swap) ---

# Generate a dynamic config .ini containing ONLY hot-swappable settings.
# Pulls from both GameUserSettings.ServerSettings and Game.ShooterGameMode,
# outputs everything under [ServerSettings] for ARK's dynamic config format.
ark_generate_dynamic_config_ini() {
    local preset_file="$1"

    local resolved_settings
    resolved_settings=$(ark_resolve_preset "$preset_file") || return 1

    local gus_server
    gus_server=$(echo "$resolved_settings" | jq '.GameUserSettings.ServerSettings // {}')
    local game_mode
    game_mode=$(echo "$resolved_settings" | jq '.Game."/Script/ShooterGame.ShooterGameMode" // {}')

    echo "[ServerSettings]"

    for key in "${ARK_HOT_SWAPPABLE_SETTINGS[@]}"; do
        # Check GameUserSettings.ServerSettings first, then Game.ShooterGameMode
        local value
        value=$(echo "$gus_server" | jq -r --arg k "$key" '.[$k] // empty')
        if [[ -z "$value" ]]; then
            value=$(echo "$game_mode" | jq -r --arg k "$key" '.[$k] // empty')
        fi
        if [[ -n "$value" ]]; then
            [[ "$value" == "true" ]] && value="True"
            [[ "$value" == "false" ]] && value="False"
            echo "${key}=${value}"
        fi
    done
}

# Write dynamic config .ini to the shared nginx volume
ark_write_dynamic_config() {
    local volume_name="$1"
    local preset_file="$2"
    local env="$3"
    local instance="$4"

    log_info "Writing dynamic config to volume: $volume_name"

    local config_content
    config_content=$(ark_generate_dynamic_config_ini "$preset_file") || return 1

    local temp_file
    temp_file=$(mktemp)
    echo "$config_content" > "$temp_file"

    local temp_container="temp-ark-dynconfig-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:/config" \
        ubuntu:22.04 sleep 60 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container for dynamic config"
        rm -f "$temp_file"
        return 1
    fi

    docker cp "$temp_file" "$temp_container:/config/GameUserSettings.ini"
    # nginx:alpine runs as nginx user — ensure the file is world-readable
    docker exec "$temp_container" chmod 644 /config/GameUserSettings.ini 2>/dev/null
    local result=$?

    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -f "$temp_file"

    if [[ $result -eq 0 ]]; then
        log_success "Dynamic config written"
        return 0
    else
        log_error "Failed to write dynamic config"
        return 1
    fi
}

# Check if ALL changed settings between two presets are hot-swappable.
# Returns 0 if hot swap is possible, 1 if any setting requires restart.
ark_is_hot_swappable() {
    local current_preset_file="$1"
    local new_preset_file="$2"

    local current_settings new_settings
    current_settings=$(ark_resolve_preset "$current_preset_file") || return 1
    new_settings=$(ark_resolve_preset "$new_preset_file") || return 1

    # Get all changed keys across both ini file sections
    local changed_keys
    changed_keys=$(jq -n --argjson a "$current_settings" --argjson b "$new_settings" '
        # Flatten all settings into key=value pairs for comparison
        def flatten_section(ini; section):
            (ini[ini_name][section] // {}) | to_entries[] | {key: .key, value: .value};

        # Collect all keys from both GameUserSettings and Game sections
        ([$a, $b] | map(
            (.GameUserSettings // {} | to_entries[] | .value | to_entries[] | .key),
            (.Game // {} | to_entries[] | .value | to_entries[] | .key)
        ) | flatten | unique) as $all_keys |

        # For each key, compare values across all sections
        [$all_keys[] | . as $key |
            # Find value in current preset (check all sections)
            ([$a.GameUserSettings // {} | to_entries[] | .value[$key] // null] +
             [$a.Game // {} | to_entries[] | .value[$key] // null] | map(select(. != null)) | first // null) as $old_val |
            # Find value in new preset
            ([$b.GameUserSettings // {} | to_entries[] | .value[$key] // null] +
             [$b.Game // {} | to_entries[] | .value[$key] // null] | map(select(. != null)) | first // null) as $new_val |
            select($old_val != $new_val) | $key
        ] | unique | .[]
    ' -r 2>/dev/null)

    if [[ -z "$changed_keys" ]]; then
        log_info "No settings changed between presets"
        return 0
    fi

    # Check each changed key against the allowlist
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local is_hot=false
        for hot_key in "${ARK_HOT_SWAPPABLE_SETTINGS[@]}"; do
            if [[ "$key" == "$hot_key" ]]; then
                is_hot=true
                break
            fi
        done
        if [[ "$is_hot" == false ]]; then
            log_info "Setting '$key' requires server restart (not hot-swappable)"
            return 1
        fi
    done <<< "$changed_keys"

    log_info "All changed settings are hot-swappable"
    return 0
}

# --- State tracking ---

ark_save_active_preset() {
    local instance="$1"
    local env="$2"
    local preset="$3"

    local state_dir="${REPO_ROOT}/.state"
    mkdir -p "$state_dir"

    echo "$preset" > "${state_dir}/ark-${env}-${instance}.preset"
    log_info "Saved active preset state: $preset"
}

ark_get_active_preset() {
    local instance="$1"
    local env="$2"

    local state_file="${REPO_ROOT}/.state/ark-${env}-${instance}.preset"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# --- Core server operations ---

ark_start_server() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"  # optional
    local preset="$4"  # preset name passed from server-manager

    log_info "Starting ARK SA server: $instance (env: $env, preset: $preset)"

    # Get naming
    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")
    local volume_name
    volume_name=$(get_volume_name "ark" "$instance" "$env")
    local preset_file="${ARK_PRESETS_DIR}/${preset}.json"

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
    local ports
    ports=($(get_port_assignments "ark" "$instance" "$env"))
    local game_port="${ports[0]}"
    local query_port="${ports[1]}"
    local rcon_port="${ports[2]}"

    log_info "Using ports: Game=$game_port, RCON=$rcon_port"

    # Get server infrastructure settings from environment config
    local env_config
    env_config=$(get_game_env_config "ark" "$env")
    local server_name="ARK-${instance}"
    local admin_password=""
    local server_password=""
    local max_players=70
    local restart_policy="unless-stopped"
    local memory_limit="16g"
    local map="TheIsland_WP"
    local rcon_enabled="TRUE"
    local update_on_boot="FALSE"
    local mod_ids=""
    local passive_mods=""
    local server_files_volume="ark-server-files-${env}"
    local dynamic_config_volume="ark-dynconfig-${env}-${instance}"

    if [[ -f "$env_config" ]] && command -v jq >/dev/null 2>&1; then
        local base_name
        base_name=$(jq -r '.server_infrastructure.base_server_name // "ARK Server"' "$env_config")
        local instance_desc
        instance_desc=$(jq -r ".instances.\"$instance\".description // \"$instance\"" "$env_config")
        server_name="${base_name} - ${instance_desc}"
        admin_password=$(jq -r '.server_infrastructure.admin_password // ""' "$env_config")
        server_password=$(jq -r '.server_infrastructure.base_password // ""' "$env_config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 70" "$env_config")
        restart_policy=$(jq -r '.docker_config.restart_policy // "unless-stopped"' "$env_config")
        memory_limit=$(jq -r '.docker_config.memory_limit // "16g"' "$env_config")
        map=$(jq -r ".instances.\"$instance\".map // \"TheIsland_WP\"" "$env_config")
        server_files_volume=$(jq -r ".game.server_files_volume // \"ark-server-files-${env}\"" "$env_config")
        # Acekorneya image uses TRUE/FALSE (uppercase)
        local rcon_raw
        rcon_raw=$(jq -r '.network_config.rcon_enabled // true' "$env_config")
        [[ "$rcon_raw" == "true" ]] && rcon_enabled="TRUE" || rcon_enabled="FALSE"
        mod_ids=$(jq -r ".instances.\"$instance\".mod_ids // \"\"" "$env_config")
        passive_mods=$(jq -r ".instances.\"$instance\".passive_mods // \"\"" "$env_config")
    fi

    # Generate docker-compose file from template
    local compose_file="${REPO_ROOT}/docker-compose-ark-${env}-${instance}.yml"
    local template_file="${ARK_DOCKER_DIR}/docker-compose.template.yml"

    if [[ ! -f "$template_file" ]]; then
        log_error "Docker compose template not found: $template_file"
        return 1
    fi

    # Create context-specific compose file
    log_info "Generating compose file: $compose_file"

    INSTANCE="$instance" \
    GAME_PORT="$game_port" \
    QUERY_PORT="$query_port" \
    RCON_PORT="$rcon_port" \
    VOLUME_NAME="$volume_name" \
    SERVER_FILES_VOLUME="$server_files_volume" \
    DYNAMIC_CONFIG_VOLUME="$dynamic_config_volume" \
    CONTAINER_NAME="$container_name" \
    SERVER_NAME="$server_name" \
    ADMIN_PASSWORD="$admin_password" \
    SERVER_PASSWORD="$server_password" \
    MAX_PLAYERS="$max_players" \
    RESTART_POLICY="$restart_policy" \
    MEMORY_LIMIT="$memory_limit" \
    MAP="$map" \
    RCON_ENABLED="$rcon_enabled" \
    UPDATE_ON_BOOT="$update_on_boot" \
    MOD_IDS="$mod_ids" \
    PASSIVE_MODS="$passive_mods" \
    envsubst < "$template_file" > "$compose_file"

    # Create Docker volumes if they don't exist
    # Server files volume is shared across instances in the same environment
    if ! volume_exists "$server_files_volume"; then
        log_info "Creating server files volume: $server_files_volume"
        docker volume create "$server_files_volume" >/dev/null
    fi
    if ! volume_exists "$volume_name"; then
        log_info "Creating save data volume: $volume_name"
        docker volume create "$volume_name" >/dev/null
    fi
    # Dynamic config volume for the nginx sidecar (hot swap support)
    if ! volume_exists "$dynamic_config_volume"; then
        log_info "Creating dynamic config volume: $dynamic_config_volume"
        docker volume create "$dynamic_config_volume" >/dev/null
    fi
    # Seed dynamic config with initial preset settings
    ark_write_dynamic_config "$dynamic_config_volume" "$preset_file" "$env" "$instance"

    # If backup file specified, restore world data BEFORE starting container
    if [[ -n "$backup_file" ]]; then
        log_info "Restoring world data from backup: $backup_file"

        # Find backup file if not full path
        if [[ ! -f "$backup_file" ]]; then
            local found_backup=""
            for search_path in "${REPO_ROOT}/backups/${env}/${instance}/${backup_file}" "${REPO_ROOT}/backups/${env}/*/${backup_file}" "$backup_file"; do
                for match in $search_path; do
                    if [[ -f "$match" ]]; then
                        found_backup="$match"
                        break 2
                    fi
                done
            done

            if [[ -z "$found_backup" ]]; then
                log_error "Backup file not found: $backup_file"
                return 1
            fi
            backup_file="$found_backup"
        fi

        if ! ark_restore_data "$instance" "$env" "$backup_file"; then
            log_error "Failed to restore world data from backup"
            return 1
        fi

        log_success "World data restored from backup before server start"
    fi

    # Inject GameUserSettings.ini and Game.ini into the volume before starting
    if ! ark_inject_settings "$volume_name" "$preset_file" "$env" "$instance"; then
        log_error "Failed to inject game settings into volume"
        return 1
    fi

    # Start server using generated compose file
    log_info "Starting ARK container: $container_name"
    docker compose -p "$container_name" -f "$compose_file" up -d

    if [[ $? -eq 0 ]]; then
        log_success "ARK SA server started: $container_name"

        # Save active preset state
        ark_save_active_preset "$instance" "$env" "$preset"

        # Wait a bit and show server info
        sleep 5
        echo
        echo "=== Server Information ==="
        echo "  Game: ark"
        echo "  Instance: $instance"
        echo "  Environment: $env"
        echo "  Map: $map"
        echo "  Preset: $preset"
        echo "  Container: $container_name"
        echo "  Volume: $volume_name"
        echo "  Game Port: $game_port"
        echo "  RCON Port: $rcon_port"

        if [[ -n "$backup_file" ]]; then
            echo "  Restored from: $(basename "$backup_file")"
        fi

        return 0
    else
        log_error "Failed to start ARK SA server: $container_name"
        return 1
    fi
}

ark_stop_server() {
    local instance="$1"
    local env="$2"

    log_info "Stopping ARK SA server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")
    local compose_file="${REPO_ROOT}/docker-compose-ark-${env}-${instance}.yml"

    # Try to save world via RCON before stopping
    if container_running "$container_name"; then
        log_info "Sending SaveWorld command via RCON..."
        ark_rcon_command "$instance" "$env" "SaveWorld" 2>/dev/null || true
        sleep 3
    fi

    # Try to use compose file if it exists
    local stop_rc=0
    if [[ -f "$compose_file" ]]; then
        log_info "Using compose file: $compose_file"
        docker compose -p "$container_name" -f "$compose_file" down || stop_rc=$?
    else
        log_info "No compose file found, stopping container directly"
        if container_exists "$container_name"; then
            docker stop "$container_name" 2>/dev/null || stop_rc=$?
            docker rm "$container_name" 2>/dev/null || true
        fi
    fi

    # Also stop the config sidecar if still running
    local config_container="${container_name}-config"
    if container_exists "$config_container"; then
        log_info "Stopping config sidecar: $config_container"
        docker stop "$config_container" 2>/dev/null || true
        docker rm "$config_container" 2>/dev/null || true
    fi

    # Verify the container is actually gone
    if container_exists "$container_name"; then
        log_warning "Container $container_name is still running after stop attempt"
        log_error "Failed to stop ARK SA server: $container_name"
        return 1
    fi

    log_success "ARK SA server stopped: $container_name"
    return 0
}

ark_restart_server() {
    local instance="$1"
    local env="$2"

    log_info "Restarting ARK SA server: $instance (env: $env)"

    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")

    # Check if server is running
    if ! container_running "$container_name"; then
        log_warning "Server not currently running: $instance"
        log_info "Starting server instead..."
        local active_preset
        active_preset=$(ark_get_active_preset "$instance" "$env")
        if [[ "$active_preset" == "unknown" ]]; then
            local env_config
            env_config=$(get_game_env_config "ark" "$env")
            active_preset=$(jq -r ".instances.\"$instance\".default_preset // \"default\"" "$env_config" 2>/dev/null || echo "default")
        fi
        ark_start_server "$instance" "$env" "" "$active_preset"
        return $?
    fi

    local compose_file="${REPO_ROOT}/docker-compose-ark-${env}-${instance}.yml"

    if [[ -f "$compose_file" ]]; then
        docker compose -p "$container_name" -f "$compose_file" restart
    else
        docker restart "$container_name"
    fi

    if [[ $? -eq 0 ]]; then
        log_success "ARK SA server restarted: $container_name"
        return 0
    else
        log_error "Failed to restart ARK SA server: $container_name"
        return 1
    fi
}

ark_health_check() {
    local context="$1"
    local env="$2"

    local container_name
    container_name=$(get_container_name "ark" "$context" "$env")

    # Basic container health check
    if ! container_running "$container_name"; then
        log_error "ARK SA server health check failed: container not running"
        return 1
    fi

    # Check if container is healthy (if health check is configured in Docker)
    local container_status
    container_status=$(docker inspect "$container_name" --format='{{.State.Health.Status}}' 2>/dev/null)
    if [[ "$container_status" == "unhealthy" ]]; then
        log_error "ARK SA server health check failed: container unhealthy"
        return 1
    fi

    # Check if game port is listening
    local ports
    ports=($(get_port_assignments "ark" "$context" "$env"))
    local game_port="${ports[0]}"

    if ! ss -tuln | grep -q ":$game_port "; then
        log_warning "Game port $game_port not listening"
    fi

    # Try RCON health check if enabled
    local env_config
    env_config=$(get_game_env_config "ark" "$env")
    local rcon_enabled
    rcon_enabled=$(jq -r '.network_config.rcon_enabled // false' "$env_config" 2>/dev/null || echo "false")

    if [[ "$rcon_enabled" == "true" ]]; then
        if ark_rcon_command "$context" "$env" "ListPlayers" >/dev/null 2>&1; then
            log_success "ARK SA server health check passed: RCON responsive"
        else
            log_warning "RCON not responsive (server may still be starting)"
        fi
    fi

    log_success "ARK SA server health check passed: $context"
    return 0
}

# --- Config swap ---

ark_config_swap() {
    local instance="$1"
    local env="$2"
    local new_preset="$3"

    log_info "Swapping ARK config: $instance -> $new_preset (env: $env)"

    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")
    local new_preset_file="${ARK_PRESETS_DIR}/${new_preset}.json"

    # Validate new preset exists and is valid
    if ! ark_validate_preset "$new_preset_file" "$instance" "$env"; then
        return 1
    fi

    # --- Hot swap path: if server is running and all changes are hot-swappable ---
    if container_running "$container_name"; then
        local current_preset
        current_preset=$(ark_get_active_preset "$instance" "$env")
        local current_preset_file="${ARK_PRESETS_DIR}/${current_preset}.json"

        if [[ "$current_preset" != "unknown" && -f "$current_preset_file" ]] && \
           ark_is_hot_swappable "$current_preset_file" "$new_preset_file"; then

            log_info "Performing hot config swap (no restart)..."
            local dynamic_config_volume="ark-dynconfig-${env}-${instance}"

            if ark_write_dynamic_config "$dynamic_config_volume" "$new_preset_file" "$env" "$instance"; then
                log_info "Triggering ForceUpdateDynamicConfig via RCON..."
                if ark_rcon_command "$instance" "$env" "ForceUpdateDynamicConfig"; then
                    log_success "Hot config swap completed: $instance now running preset '$new_preset'"

                    # Update static ini files so next cold restart uses the new preset
                    local volume_name
                    volume_name=$(get_volume_name "ark" "$instance" "$env")
                    ark_inject_settings "$volume_name" "$new_preset_file" "$env" "$instance" 2>/dev/null || true

                    ark_save_active_preset "$instance" "$env" "$new_preset"
                    return 0
                else
                    log_warning "RCON ForceUpdateDynamicConfig failed, falling back to cold swap"
                fi
            else
                log_warning "Failed to write dynamic config, falling back to cold swap"
            fi
        else
            log_info "Preset changes include restart-required settings, using cold swap"
        fi
    else
        log_info "Server is stopped, using cold swap"
    fi

    # --- Cold swap path: stop, reconfigure, start ---
    log_info "Creating pre-swap backup..."
    ark_backup_data "$instance" "$env" "pre-swap_${new_preset}_$(date +%Y%m%d_%H%M%S)"

    log_info "Stopping server for config swap..."
    ark_stop_server "$instance" "$env"

    log_info "Starting server with new preset: $new_preset"
    if ark_start_server "$instance" "$env" "" "$new_preset"; then
        log_success "Config swap completed (cold): $instance now running preset '$new_preset'"
        return 0
    else
        log_error "Failed to start server with new preset: $new_preset"
        return 1
    fi
}

# --- Backup and restore ---

ark_backup_data() {
    local instance="$1"
    local env="$2"
    local backup_name="$3"  # optional
    local active_preset="$4"  # currently active preset

    log_info "Backing up ARK SA data: $instance (env: $env)"

    local volume_name
    volume_name=$(get_volume_name "ark" "$instance" "$env")

    # Check if volume exists
    if ! volume_exists "$volume_name"; then
        log_error "Volume not found: $volume_name"
        return 1
    fi

    # Get active preset from state if not provided
    if [[ -z "$active_preset" ]]; then
        active_preset=$(ark_get_active_preset "$instance" "$env")
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

    # If server is running, trigger save via RCON
    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")
    if container_running "$container_name"; then
        log_info "Server running, triggering SaveWorld via RCON..."
        if ark_rcon_command "$instance" "$env" "SaveWorld" 2>/dev/null; then
            log_success "World save triggered successfully"
            sleep 5
        else
            log_warning "Failed to trigger save via RCON, proceeding with current data"
        fi
    else
        log_info "Server not running, backing up current volume state"
    fi

    # Create temporary container to access volume
    # Volume mounts at ARK_VOLUME_MOUNT and contains ShooterGame/Saved contents directly
    local temp_container="temp-ark-extract-${instance}-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:${ARK_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi

    # Create temporary directory for extraction
    local temp_dir
    temp_dir=$(mktemp -d)

    # Copy volume contents (SavedArks, Config, Logs, etc.)
    docker cp "$temp_container:${ARK_VOLUME_MOUNT}/." "$temp_dir/" 2>/dev/null || true

    # Get port assignments for metadata
    local ports
    ports=($(get_port_assignments "ark" "$instance" "$env"))

    # Get infrastructure info from game environment config
    local config
    config=$(get_game_env_config "ark" "$env")
    local server_name="Unknown"
    local max_players=70
    local map="Unknown"

    if [[ -f "$config" ]] && command -v jq >/dev/null 2>&1; then
        server_name=$(jq -r ".instances.\"$instance\".description // \"Unknown\"" "$config")
        max_players=$(jq -r ".instances.\"$instance\".max_players // 70" "$config")
        map=$(jq -r ".instances.\"$instance\".map // \"Unknown\"" "$config")
    fi

    # Create metadata file
    cat > "$meta_file" << META_EOF
{
    "game": "ark",
    "instance": "$instance",
    "environment": "$env",
    "map": "$map",
    "active_preset": "${active_preset:-unknown}",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "infrastructure": {
        "ports": {
            "game": ${ports[0]},
            "peer": $((ports[0] + 1)),
            "query": ${ports[1]},
            "rcon": ${ports[2]}
        },
        "server_name": "$server_name",
        "max_players": $max_players
    },
    "preset_location": "games/ark/presets/${active_preset:-unknown}.json",
    "volume_name": "$volume_name",
    "container_name": "ark-${env}-${instance}",
    "backup_method": "docker_volume"
}
META_EOF

    # Create tar archive
    (cd "$temp_dir" && tar -czf "$backup_file" .)

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    if [[ -f "$backup_file" ]]; then
        local backup_size
        backup_size=$(du -sh "$backup_file" | cut -f1)
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

ark_restore_data() {
    local instance="$1"
    local env="$2"
    local backup_file="$3"

    log_info "Restoring ARK SA data: $instance from $backup_file (env: $env)"

    # Search for backup file if not a full path
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
            log_info "Found backup: $found_backup"
            backup_file="$found_backup"
        else
            log_error "Backup file not found: $backup_file"
            return 1
        fi
    fi

    local volume_name
    volume_name=$(get_volume_name "ark" "$instance" "$env")

    # Extract backup to temp directory
    local temp_dir
    temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi

    # Create temporary container to access volume
    # Volume maps to ShooterGame/Saved directly
    local temp_container="temp-ark-restore-${instance}-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:${ARK_VOLUME_MOUNT}" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary restore container"
        rm -rf "$temp_dir"
        return 1
    fi

    # Clear existing volume contents and replace with backup
    log_info "Clearing existing save data..."
    docker exec "$temp_container" sh -c "rm -rf ${ARK_VOLUME_MOUNT}/*" 2>/dev/null || true

    log_info "Restoring save data from backup..."
    docker cp "$temp_dir/." "$temp_container:${ARK_VOLUME_MOUNT}/"

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    log_success "ARK SA world restoration completed successfully"
    log_info "Volume: $volume_name"

    return 0
}

# --- RCON helper ---

ark_rcon_command() {
    local instance="$1"
    local env="$2"
    local command="$3"

    local container_name
    container_name=$(get_container_name "ark" "$instance" "$env")

    local env_config
    env_config=$(get_game_env_config "ark" "$env")
    local admin_password
    admin_password=$(jq -r '.server_infrastructure.admin_password // ""' "$env_config" 2>/dev/null || echo "")

    # Use rcon-cli inside the container (provided by Acekorneya image)
    local ports
    ports=($(get_port_assignments "ark" "$instance" "$env"))
    local rcon_port="${ports[2]}"

    docker exec "$container_name" rcon-cli -a "127.0.0.1:${rcon_port}" -p "$admin_password" "$command" 2>/dev/null
}

# --- Utilities ---

ark_get_ports() {
    local context="$1"
    local env="$2"

    # Return ports used by ARK (game, query, rcon, restapi_placeholder)
    get_port_assignments "ark" "$context" "$env"
}

ark_validate_preset() {
    local preset_file="$1"
    local context="$2"
    local env="$3"

    log_info "Validating ARK preset: $preset_file"

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

    if ! jq -e '.game_settings.GameUserSettings' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'game_settings.GameUserSettings' section: $preset_file"
        return 1
    fi

    if ! jq -e '.game_settings.Game' "$preset_file" >/dev/null 2>&1; then
        log_error "Preset missing required 'game_settings.Game' section: $preset_file"
        return 1
    fi

    if ! jq -e '.metadata.name' "$preset_file" >/dev/null 2>&1; then
        log_warning "Preset missing 'metadata.name': $preset_file"
    fi

    # Validate parent preset exists if inherits is set
    local inherits
    inherits=$(jq -r '.metadata.inherits // empty' "$preset_file")
    if [[ -n "$inherits" ]]; then
        local parent_file="${ARK_PRESETS_DIR}/${inherits}"
        if [[ ! -f "$parent_file" ]]; then
            log_error "Parent preset not found: $parent_file"
            return 1
        fi
    fi

    log_success "ARK preset validation passed: $preset_file"
    return 0
}

# Export plugin functions
export -f ark_start_server ark_stop_server ark_restart_server
export -f ark_health_check ark_config_swap
export -f ark_backup_data ark_restore_data
export -f ark_get_ports ark_validate_preset
export -f ark_resolve_preset ark_generate_game_user_settings_ini ark_generate_game_ini
export -f ark_inject_settings ark_rcon_command
export -f ark_generate_dynamic_config_ini ark_write_dynamic_config ark_is_hot_swappable
export -f ark_save_active_preset ark_get_active_preset
