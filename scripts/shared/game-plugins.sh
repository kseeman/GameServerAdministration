#!/bin/bash

# Game Plugin System - Loads and manages game-specific plugins

# Source shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/server-utils.sh"

# Plugin loading functions
load_game_plugin() {
    local game="$1"
    local env="${2:-production}"
    
    if [[ -z "$game" ]]; then
        log_error "Game name required for plugin loading"
        return 1
    fi
    
    # Validate game exists in registry
    if ! validate_game "$game" "$env"; then
        return 1
    fi
    
    # Get plugin path from registry
    local plugin_script=$(get_game_info "$game" "$env" "plugin_script")
    if [[ "$plugin_script" == "null" || "$plugin_script" == "unknown" ]]; then
        plugin_script="games/${game}/scripts/game-specific-logic.sh"
        log_info "Using default plugin path: $plugin_script"
    fi
    
    local plugin_path="${REPO_ROOT}/${plugin_script}"
    
    if [[ ! -f "$plugin_path" ]]; then
        log_error "Game plugin not found: $plugin_path"
        return 1
    fi
    
    # Source the plugin
    source "$plugin_path"
    
    if [[ $? -eq 0 ]]; then
        log_success "Loaded plugin for game: $game"
        return 0
    else
        log_error "Failed to load plugin for game: $game"
        return 1
    fi
}

# Check if a game plugin function exists
plugin_function_exists() {
    local game="$1"
    local operation="$2"
    
    local function_name="${game}_${operation}"
    
    if declare -f "$function_name" >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Call a game plugin function with error handling
call_plugin_function() {
    local game="$1"
    local operation="$2"
    shift 2  # Remove game and operation from arguments
    local args="$@"
    
    local function_name="${game}_${operation}"
    
    if ! plugin_function_exists "$game" "$operation"; then
        log_error "Plugin function not found: $function_name"
        log_info "Available functions for $game:"
        declare -f | grep "^${game}_" | sed 's/ () $//' | sed 's/^/  /'
        return 1
    fi
    
    log_info "Calling plugin function: $function_name"
    
    # Call the plugin function with remaining arguments
    "$function_name" "$@"
    
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_success "Plugin function completed successfully: $function_name"
    else
        log_error "Plugin function failed: $function_name (exit code: $result)"
    fi
    
    return $result
}

# List available operations for a game
list_game_operations() {
    local game="$1"
    local env="${2:-production}"
    
    if ! validate_game "$game" "$env"; then
        return 1
    fi
    
    # Get supported operations from registry
    local operations=$(get_game_info "$game" "$env" "supported_operations")
    
    if [[ "$operations" != "null" && "$operations" != "unknown" ]]; then
        echo "$operations" | jq -r '.[]' 2>/dev/null
    else
        # Fallback: detect functions by introspection
        log_warning "No supported_operations in registry, detecting from loaded plugin..."
        if load_game_plugin "$game" "$env"; then
            declare -f | grep "^${game}_" | sed "s/^${game}_//" | sed 's/ () $//'
        fi
    fi
}

# Validate that a game plugin implements required functions
validate_game_plugin() {
    local game="$1"
    local env="${2:-production}"
    
    if ! load_game_plugin "$game" "$env"; then
        return 1
    fi
    
    local required_functions=(
        "start_server"
        "stop_server" 
        "health_check"
        "get_ports"
        "validate_preset"
    )
    
    local missing_functions=()
    
    for func in "${required_functions[@]}"; do
        if ! plugin_function_exists "$game" "$func"; then
            missing_functions+=("${game}_${func}")
        fi
    done
    
    if [[ ${#missing_functions[@]} -gt 0 ]]; then
        log_error "Game plugin missing required functions:"
        for func in "${missing_functions[@]}"; do
            log_error "  - $func"
        done
        return 1
    fi
    
    log_success "Game plugin validation passed for: $game"
    return 0
}

# Create a minimal plugin template for a new game
create_plugin_template() {
    local game="$1"
    
    if [[ -z "$game" ]]; then
        log_error "Game name required for plugin template creation"
        return 1
    fi
    
    if ! validate_naming_convention "$game" "game"; then
        return 1
    fi
    
    local plugin_dir="${REPO_ROOT}/games/${game}/scripts"
    local plugin_file="${plugin_dir}/game-specific-logic.sh"
    
    if [[ -f "$plugin_file" ]]; then
        log_error "Plugin already exists: $plugin_file"
        return 1
    fi
    
    mkdir -p "$plugin_dir"
    
    cat > "$plugin_file" << EOF
#!/bin/bash

# ${game^} Game Plugin - Game-specific server management functions
# This plugin implements the required interface for ${game} server management

# Source shared utilities
source "\$(dirname "\${BASH_SOURCE[0]}")/../../scripts/shared/server-utils.sh"

# Required plugin functions for ${game}

${game}_start_server() {
    local context="\$1"
    local env="\$2"
    local backup_file="\$3"  # optional
    
    log_info "Starting ${game} server: \$context (env: \$env)"
    
    # TODO: Implement ${game}-specific server startup logic
    # Example:
    # 1. Generate docker-compose file from template
    # 2. Apply game-specific environment variables
    # 3. Start Docker container
    # 4. Wait for server to become ready
    
    log_error "${game}_start_server not yet implemented"
    return 1
}

${game}_stop_server() {
    local context="\$1"
    local env="\$2"
    
    log_info "Stopping ${game} server: \$context (env: \$env)"
    
    # TODO: Implement ${game}-specific server shutdown logic
    # Example:
    # 1. Send graceful shutdown signal to game server
    # 2. Wait for clean shutdown
    # 3. Stop Docker container
    
    log_error "${game}_stop_server not yet implemented"
    return 1
}

${game}_restart_server() {
    local context="\$1"
    local env="\$2"
    
    log_info "Restarting ${game} server: \$context (env: \$env)"
    
    if ${game}_stop_server "\$context" "\$env"; then
        sleep 5
        ${game}_start_server "\$context" "\$env"
    else
        return 1
    fi
}

${game}_health_check() {
    local context="\$1"
    local env="\$2"
    
    # TODO: Implement ${game}-specific health check
    # Example:
    # 1. Check if container is running
    # 2. Check if game ports are listening
    # 3. Query game server status (if supported)
    # 4. Verify player can connect
    
    local container_name=\$(get_container_name "${game}" "\$context" "\$env")
    
    if container_running "\$container_name"; then
        log_success "${game} server health check passed: \$context"
        return 0
    else
        log_error "${game} server health check failed: \$context"
        return 1
    fi
}

${game}_config_swap() {
    local context="\$1"
    local env="\$2"
    local new_preset="\$3"
    
    log_info "Swapping ${game} config: \$context -> \$new_preset (env: \$env)"
    
    # TODO: Implement ${game}-specific configuration swapping
    # Example:
    # 1. Validate new preset
    # 2. Create backup of current config
    # 3. Update configuration files
    # 4. Restart server with new config
    # 5. Verify server starts correctly
    
    log_error "${game}_config_swap not yet implemented"
    return 1
}

${game}_backup_data() {
    local context="\$1"
    local env="\$2"
    local backup_name="\$3"  # optional
    
    log_info "Backing up ${game} data: \$context (env: \$env)"
    
    # TODO: Implement ${game}-specific backup logic
    # Example:
    # 1. Identify game data directories
    # 2. Create consistent backup (may require server pause)
    # 3. Compress backup data
    # 4. Store with proper naming convention
    
    log_error "${game}_backup_data not yet implemented"
    return 1
}

${game}_restore_data() {
    local context="\$1"
    local env="\$2"
    local backup_file="\$3"
    
    log_info "Restoring ${game} data: \$context from \$backup_file (env: \$env)"
    
    # TODO: Implement ${game}-specific restore logic
    # Example:
    # 1. Validate backup file
    # 2. Stop server if running
    # 3. Extract backup to correct locations
    # 4. Update any configuration references
    # 5. Start server with restored data
    
    log_error "${game}_restore_data not yet implemented"
    return 1
}

${game}_get_ports() {
    local context="\$1"
    local env="\$2"
    
    # TODO: Return actual ports used by ${game}
    # This should return the ports in the format: "game_port query_port rcon_port api_port"
    
    get_port_assignments "${game}" "\$context" "\$env"
}

${game}_validate_preset() {
    local preset_file="\$1"
    local context="\$2"
    local env="\$3"
    
    log_info "Validating ${game} preset: \$preset_file"
    
    if [[ ! -f "\$preset_file" ]]; then
        log_error "Preset file not found: \$preset_file"
        return 1
    fi
    
    # TODO: Implement ${game}-specific preset validation
    # Example:
    # 1. Check required variables are present
    # 2. Validate value ranges and formats
    # 3. Check for ${game}-specific configuration conflicts
    # 4. Verify preset is compatible with game version
    
    log_success "${game} preset validation passed: \$preset_file"
    return 0
}

# Export plugin functions
export -f ${game}_start_server ${game}_stop_server ${game}_restart_server
export -f ${game}_health_check ${game}_config_swap
export -f ${game}_backup_data ${game}_restore_data
export -f ${game}_get_ports ${game}_validate_preset
EOF

    chmod +x "$plugin_file"
    
    log_success "Created plugin template: $plugin_file"
    log_info "Edit this file to implement ${game}-specific server management logic"
    
    return 0
}

# Export functions
export -f load_game_plugin plugin_function_exists call_plugin_function
export -f list_game_operations validate_game_plugin create_plugin_template