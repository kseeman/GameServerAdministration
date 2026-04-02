#!/bin/bash

# Game-Agnostic Server Utilities - Shared functions for multi-game server management
# Provides registry validation, safety checks, and common functionality

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the path to a game's environment config file
# All game-specific config lives under games/<game>/environments/<env>.json
get_game_env_config() {
    local game="$1"
    local env="$2"
    echo "${REPO_ROOT}/games/${game}/environments/${env}.json"
}

# Environment validation
validate_environment() {
    local env="$1"

    if [[ "$env" != "staging" && "$env" != "production" ]]; then
        log_error "Invalid environment: $env. Must be 'staging' or 'production'"
        return 1
    fi

    return 0
}

# Game validation - checks that a game environment config exists
validate_game() {
    local game="$1"
    local env="$2"

    if [[ -z "$game" || -z "$env" ]]; then
        log_error "Game and environment required for validation"
        return 1
    fi

    if ! validate_environment "$env"; then
        return 1
    fi

    local config=$(get_game_env_config "$game" "$env")

    if [[ ! -f "$config" ]]; then
        log_error "Game config not found: $config"
        return 1
    fi

    log_success "Game '$game' validated in $env environment"
    return 0
}

# Instance validation using game environment config
validate_instance() {
    local game="$1"
    local instance="$2"
    local env="$3"

    if [[ -z "$game" || -z "$instance" || -z "$env" ]]; then
        log_error "Game, instance, and environment required for validation"
        return 1
    fi

    if ! validate_game "$game" "$env"; then
        return 1
    fi

    local config=$(get_game_env_config "$game" "$env")

    if ! command -v jq >/dev/null 2>&1; then
        log_warning "jq not available, skipping instance validation"
        return 0
    fi

    if jq -r ".instances.\"$instance\"" "$config" | grep -q "null"; then
        log_warning "Instance '$instance' not found in $game config for $env"
        log_info "Available instances: $(jq -r '.instances | keys | join(", ")' "$config" 2>/dev/null || echo "none")"
        return 1
    fi

    log_success "Instance '$instance' validated for $game in $env environment"
    return 0
}

# Generate safe volume name (game-agnostic)
get_volume_name() {
    local game="$1"
    local instance="$2"
    local env="$3"

    if [[ -z "$game" || -z "$instance" || -z "$env" ]]; then
        log_error "Game, instance, and environment required for volume name"
        return 1
    fi

    if ! validate_environment "$env"; then
        return 1
    fi

    echo "${game}-vol-${env}-${instance}"
}

# Generate safe container name (game-agnostic)
get_container_name() {
    local game="$1"
    local instance="$2"
    local env="$3"

    if [[ -z "$game" || -z "$instance" || -z "$env" ]]; then
        log_error "Game, instance, and environment required for container name"
        return 1
    fi

    if ! validate_environment "$env"; then
        return 1
    fi

    echo "${game}-${env}-${instance}"
}

# Get game information from environment config
get_game_info() {
    local game="$1"
    local env="$2"
    local field="$3"

    local config=$(get_game_env_config "$game" "$env")

    if [[ ! -f "$config" ]]; then
        log_error "Game config not found: $config"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq required for registry operations"
        return 1
    fi

    jq -r ".game.\"$field\"" "$config" 2>/dev/null || echo "unknown"
}

# Get instance information from game environment config
get_instance_info() {
    local game="$1"
    local instance="$2"
    local env="$3"
    local field="$4"

    local config=$(get_game_env_config "$game" "$env")

    if [[ ! -f "$config" ]]; then
        log_error "Game config not found: $config"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq required for registry operations"
        return 1
    fi

    jq -r ".instances.\"$instance\".\"$field\"" "$config" 2>/dev/null || echo "unknown"
}

# Check if volume exists
volume_exists() {
    local volume_name="$1"

    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Check if container exists
container_exists() {
    local container_name="$1"

    if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# Check if container is running
container_running() {
    local container_name="$1"

    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        return 0
    else
        return 1
    fi
}

# Get port assignments from game environment config with instance offset
get_port_assignments() {
    local game="$1"
    local instance="$2"
    local env="$3"

    local config=$(get_game_env_config "$game" "$env")

    if [[ ! -f "$config" ]] || ! command -v jq >/dev/null 2>&1; then
        log_warning "Cannot read port assignments from config, using defaults"
        if [[ "$env" == "staging" ]]; then
            echo "9215 28019 26577 10999"
        else
            echo "8215 27019 25577 9999"
        fi
        return 0
    fi

    # Get base ports from config
    local game_port_base=$(jq -r '.network_config.base_ports.game_port' "$config")
    local query_port_base=$(jq -r '.network_config.base_ports.query_port' "$config")
    local rcon_port_base=$(jq -r '.network_config.base_ports.rcon_port' "$config")
    local api_port_base=$(jq -r '.network_config.base_ports.restapi_port' "$config")

    # Get instance port offset
    local port_offset=$(jq -r ".instances.\"$instance\".port_offset // 0" "$config" 2>/dev/null || echo "0")

    # Apply offset per instance (uses port_offset_per_instance from config)
    local offset_multiplier=$(jq -r '.network_config.port_offset_per_instance // 1' "$config")
    local total_offset=$((port_offset * offset_multiplier))

    local game_port=$((game_port_base + total_offset))
    local query_port=$((query_port_base + total_offset))
    local rcon_port=$((rcon_port_base + total_offset))
    local api_port=$((api_port_base + total_offset))

    echo "$game_port $query_port $rcon_port $api_port"
}

# Check if ports are available
check_port_availability() {
    local ports="$1"

    for port in $ports; do
        if ss -tuln | grep -q ":$port "; then
            log_warning "Port $port is already in use"
            return 1
        fi
    done

    return 0
}

# Safety confirmation prompt (game-agnostic)
safety_confirmation() {
    local operation="$1"
    local game="$2"
    local instance="$3"
    local env="$4"
    local additional_info="$5"

    local volume_name=$(get_volume_name "$game" "$instance" "$env")
    local container_name=$(get_container_name "$game" "$instance" "$env")

    echo
    log_warning "SAFETY CHECK: About to perform $operation"
    log_info "Game: $game"
    log_info "Environment: $env"
    log_info "Instance: $instance"
    log_info "Volume: $volume_name"
    log_info "Container: $container_name"

    if volume_exists "$volume_name"; then
        local volume_size=$(docker run --rm -v "$volume_name:/data" ubuntu:22.04 du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Current Volume Size: $volume_size"
    fi

    if [[ -n "$additional_info" ]]; then
        log_info "$additional_info"
    fi

    echo
    log_warning "Type '$game-$instance' to confirm this operation:"
    read -r confirmation

    if [[ "$confirmation" != "$game-$instance" ]]; then
        log_info "Operation cancelled"
        return 1
    fi

    log_success "Confirmation received, proceeding..."
    return 0
}

# Validate naming conventions (game-agnostic)
validate_naming_convention() {
    local name="$1"
    local type="$2"  # game, context, volume, container

    case "$type" in
        "game")
            if [[ ! "$name" =~ ^[a-zA-Z0-9-]+$ ]] || [[ ${#name} -gt 16 ]]; then
                log_error "Invalid game name: $name"
                log_info "Game names must be alphanumeric with hyphens, max 16 characters"
                return 1
            fi
            ;;
        "instance")
            if [[ ! "$name" =~ ^[a-zA-Z0-9-]+$ ]] || [[ ${#name} -gt 32 ]]; then
                log_error "Invalid instance name: $name"
                log_info "Instance names must be alphanumeric with hyphens, max 32 characters"
                return 1
            fi
            ;;
        "volume")
            if [[ ! "$name" =~ ^[a-zA-Z0-9-]+-vol-(staging|production)-[a-zA-Z0-9-]+$ ]]; then
                log_error "Invalid volume name: $name"
                log_info "Volume names must follow pattern: {game}-vol-{env}-{instance}"
                return 1
            fi
            ;;
        "container")
            if [[ ! "$name" =~ ^[a-zA-Z0-9-]+-(staging|production)-[a-zA-Z0-9-]+$ ]]; then
                log_error "Invalid container name: $name"
                log_info "Container names must follow pattern: {game}-{env}-{instance}"
                return 1
            fi
            ;;
        *)
            log_error "Unknown naming validation type: $type"
            return 1
            ;;
    esac

    return 0
}

# Pre-operation safety checklist (game-agnostic)
run_safety_checklist() {
    local operation="$1"
    local game="$2"
    local instance="$3"
    local env="$4"

    log_info "Running safety checklist for $operation ($game-$instance-$env)..."

    # 1. Game exists in supported games
    if ! validate_game "$game" "$env"; then
        log_error "Safety check failed: Game validation"
        return 1
    fi

    # 2. Instance validation (warning only, allow creation of new instances)
    if ! validate_instance "$game" "$instance" "$env"; then
        log_warning "Instance not found in registry, but allowing operation to proceed"
    fi

    # 3. Volume name follows strict naming convention
    local volume_name=$(get_volume_name "$game" "$instance" "$env")
    if ! validate_naming_convention "$volume_name" "volume"; then
        log_error "Safety check failed: Volume naming convention"
        return 1
    fi

    # 4. Container name follows strict naming convention
    local container_name=$(get_container_name "$game" "$instance" "$env")
    if ! validate_naming_convention "$container_name" "container"; then
        log_error "Safety check failed: Container naming convention"
        return 1
    fi

    # 5. No container name collisions for creation operations
    if [[ "$operation" == "create" || "$operation" == "start" ]] && container_exists "$container_name"; then
        log_error "Safety check failed: Container $container_name already exists"
        return 1
    fi

    # 6. Port assignment within allowed ranges
    local ports=($(get_port_assignments "$game" "$instance" "$env"))
    if ! check_port_availability "${ports[*]}"; then
        log_error "Safety check failed: Port availability"
        return 1
    fi

    # 7. Environment separation maintained
    local opposing_env="staging"
    if [[ "$env" == "staging" ]]; then
        opposing_env="production"
    fi

    local opposing_container=$(get_container_name "$game" "$instance" "$opposing_env")
    if container_running "$opposing_container"; then
        log_warning "Container running in $opposing_env environment: $opposing_container"
        log_info "Ensure you're targeting the correct environment"
    fi

    log_success "Safety checklist passed"
    return 0
}

# Create emergency backup before destructive operations (game-agnostic)
create_emergency_backup() {
    local operation="$1"
    local game="$2"
    local instance="$3"
    local env="$4"

    local volume_name=$(get_volume_name "$game" "$instance" "$env")

    if ! volume_exists "$volume_name"; then
        log_info "No volume to backup for $game-$instance-$env"
        return 0
    fi

    log_info "Creating emergency backup before $operation..."

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="emergency_${operation}_${game}_${instance}_${env}_${timestamp}"
    local backup_dir="${REPO_ROOT}/backups/emergency"
    local backup_file="${backup_dir}/${backup_name}.tar.gz"

    mkdir -p "$backup_dir"

    # Create temporary container to access volume
    local temp_container="temp-backup-${game}-${instance}-$$"

    docker run -d --name "$temp_container" \
        -v "$volume_name:/data" \
        ubuntu:22.04 sleep 300 >/dev/null

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary backup container"
        return 1
    fi

    # Create temporary directory for backup
    local temp_dir=$(mktemp -d)

    # Copy data from volume
    docker cp "$temp_container:/data/." "$temp_dir/"

    # Create tar archive
    (cd "$temp_dir" && tar -czf "$backup_file" .)

    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"

    if [[ -f "$backup_file" ]]; then
        local backup_size=$(du -sh "$backup_file" | cut -f1)
        log_success "Emergency backup created: $backup_name ($backup_size)"
        echo "$backup_file"
        return 0
    else
        log_error "Failed to create emergency backup"
        return 1
    fi
}

# Export functions for use in other scripts
export -f log_info log_success log_warning log_error
export -f validate_environment validate_game validate_instance
export -f get_game_env_config get_volume_name get_container_name get_game_info get_instance_info
export -f volume_exists container_exists container_running
export -f get_port_assignments check_port_availability
export -f safety_confirmation validate_naming_convention
export -f run_safety_checklist create_emergency_backup
