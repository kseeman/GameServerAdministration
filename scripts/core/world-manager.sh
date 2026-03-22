#!/bin/bash

# World Data Injection/Extraction Utilities for Multi-Server Architecture
# Handles artifact-based world management with Docker volumes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
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

# Get port assignments for a context
get_port_assignments() {
    local context="$1"
    local port_offset=0
    
    # Define port offsets for known contexts
    case "$context" in
        "tournament") port_offset=0 ;;
        "hardcore") port_offset=1 ;;
        "double-xp-event") port_offset=2 ;;
        "peaceful-event") port_offset=3 ;;
        "hardcore-no-travel") port_offset=4 ;;
        *) 
            # For unknown contexts, find next available offset
            for i in {5..20}; do
                local test_port=$((8215 + i))
                if ! ss -tuln | grep -q ":$test_port "; then
                    port_offset=$i
                    break
                fi
            done
            ;;
    esac
    
    local game_port=$((8215 + port_offset))
    local query_port=$((27019 + port_offset))
    local rcon_port=$((25577 + port_offset))
    
    echo "$game_port $query_port $rcon_port"
}

# Inject world data from backup artifact into Docker volume
inject_world_data() {
    local context="$1"
    local backup_file="$2"
    
    if [[ -z "$context" || -z "$backup_file" ]]; then
        log_error "Usage: inject_world_data <context> <backup_file>"
        return 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    local volume_name="palworld-vol-${context}"
    
    log_info "Injecting world data into volume: $volume_name"
    log_info "From backup: $(basename "$backup_file")"
    
    # Create temporary container to access volume
    local temp_container="temp-inject-${context}-$$"
    
    # Create/ensure volume exists
    docker volume create "$volume_name" >/dev/null 2>&1
    
    # Start temporary container with volume mounted
    docker run -d --name "$temp_container" \
        -v "$volume_name:/opt/palworld/Pal/Saved" \
        ubuntu:22.04 sleep 3600 >/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi
    
    # Clean existing volume contents
    log_info "Cleaning existing volume contents..."
    docker exec "$temp_container" rm -rf /opt/palworld/Pal/Saved/SaveGames/0/* 2>/dev/null
    docker exec "$temp_container" mkdir -p /opt/palworld/Pal/Saved/SaveGames/0
    docker exec "$temp_container" mkdir -p /opt/palworld/Pal/Saved/Config/LinuxServer
    
    # Extract backup to temporary directory
    local temp_dir=$(mktemp -d)
    tar -xzf "$backup_file" -C "$temp_dir" --strip-components=1 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract backup file"
        docker rm -f "$temp_container" >/dev/null 2>&1
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Find world ID from extracted backup
    local world_id=""
    local world_dirs=($(find "$temp_dir" -name "*[A-F0-9][A-F0-9][A-F0-9][A-F0-9]*" -type d | grep -E "SaveGames/0/[A-F0-9]{32}$"))
    
    if [[ ${#world_dirs[@]} -gt 0 ]]; then
        world_id=$(basename "${world_dirs[0]}")
        log_success "Found world ID in backup: $world_id"
    else
        log_error "No valid world ID found in backup"
        docker rm -f "$temp_container" >/dev/null 2>&1
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Copy world data to volume
    log_info "Copying world data to volume..."
    
    # Copy SaveGames
    if [[ -d "$temp_dir/SaveGames" ]]; then
        docker cp "$temp_dir/SaveGames/." "$temp_container:/opt/palworld/Pal/Saved/SaveGames/"
    elif [[ -d "$temp_dir/palworld-data/SaveGames" ]]; then
        docker cp "$temp_dir/palworld-data/SaveGames/." "$temp_container:/opt/palworld/Pal/Saved/SaveGames/"
    fi
    
    # Copy Config if exists
    if [[ -d "$temp_dir/Config" ]]; then
        docker cp "$temp_dir/Config/." "$temp_container:/opt/palworld/Pal/Saved/Config/"
    elif [[ -d "$temp_dir/palworld-data/Config" ]]; then
        docker cp "$temp_dir/palworld-data/Config/." "$temp_container:/opt/palworld/Pal/Saved/Config/"
    fi
    
    # Update GameUserSettings.ini with correct DedicatedServerName
    log_info "Updating GameUserSettings.ini with world ID: $world_id"
    docker exec "$temp_container" bash -c "
        mkdir -p /opt/palworld/Pal/Saved/Config/LinuxServer
        if [[ -f /opt/palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini ]]; then
            sed -i '/^\[\/Script\/Pal\.PalGameLocalSettings\]/,/^\[/ {
                /^DedicatedServerName=/ c\\
DedicatedServerName=$world_id
                /^\[\/Script\/Pal\.PalGameLocalSettings\]$/ a\\
DedicatedServerName=$world_id
            }' /opt/palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini
        else
            cat > /opt/palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini << 'GAMEUSER_EOF'
[/Script/Pal.PalGameLocalSettings]
DedicatedServerName=$world_id
GAMEUSER_EOF
        fi
    "
    
    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"
    
    log_success "World data injection completed successfully"
    log_info "Volume: $volume_name"
    log_info "World ID: $world_id"
    
    echo "$world_id"  # Return world_id for caller
}

# Extract world data from Docker volume to backup artifact
extract_world_data() {
    local context="$1"
    local backup_name="$2"
    
    if [[ -z "$context" ]]; then
        log_error "Usage: extract_world_data <context> [backup_name]"
        return 1
    fi
    
    local volume_name="palworld-vol-${context}"
    
    # Check if volume exists
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_error "Volume not found: $volume_name"
        return 1
    fi
    
    # Generate backup name if not provided
    if [[ -z "$backup_name" ]]; then
        backup_name="${context}_pvp_$(date +%Y%m%d_%H%M%S)"
    fi
    
    local backup_file="${BACKUP_DIR}/${context}/${backup_name}.tar.gz"
    local meta_file="${BACKUP_DIR}/${context}/${backup_name}.meta.json"
    
    # Ensure backup directory exists
    mkdir -p "$(dirname "$backup_file")"
    
    log_info "Extracting world data from volume: $volume_name"
    log_info "Creating backup: $(basename "$backup_file")"
    
    # Create temporary container to access volume
    local temp_container="temp-extract-${context}-$$"
    
    docker run -d --name "$temp_container" \
        -v "$volume_name:/opt/palworld/Pal/Saved" \
        ubuntu:22.04 sleep 3600 >/dev/null
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create temporary container"
        return 1
    fi
    
    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)
    
    # Copy data from volume
    docker cp "$temp_container:/opt/palworld/Pal/Saved/." "$temp_dir/"
    
    # Find world ID - Read from GameUserSettings.ini first (FIXED)
    local world_id=""
    
    # Try to get world ID from GameUserSettings.ini first (correct method)
    if [[ -f "$temp_dir/Config/LinuxServer/GameUserSettings.ini" ]]; then
        world_id=$(grep "DedicatedServerName=" "$temp_dir/Config/LinuxServer/GameUserSettings.ini" | tail -1 | cut -d'=' -f2)
        if [[ -n "$world_id" ]]; then
            log_success "Found world ID from GameUserSettings.ini: $world_id"
        fi
    fi
    
    # Fallback to filesystem discovery only if GameUserSettings.ini method failed
    if [[ -z "$world_id" ]]; then
        log_warning "Could not read world ID from GameUserSettings.ini, falling back to filesystem discovery"
        local world_dirs=($(find "$temp_dir" -name "*[A-F0-9][A-F0-9][A-F0-9][A-F0-9]*" -type d | grep -E "SaveGames/0/[A-F0-9]{32}$"))
        
        if [[ ${#world_dirs[@]} -gt 0 ]]; then
            world_id=$(basename "${world_dirs[0]}")
            log_warning "Using filesystem discovery world ID: $world_id (may not be active world!)"
        else
            log_warning "No world ID found - may be fresh server"
            world_id="unknown"
        fi
    fi
    
    # Get port assignments
    local ports=($(get_port_assignments "$context"))
    local game_port="${ports[0]}"
    local query_port="${ports[1]}"
    local rcon_port="${ports[2]}"
    
    # Create metadata file
    cat > "$meta_file" << META_EOF
{
    "context": "$context",
    "world_id": "$world_id",
    "backup_name": "$backup_name",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "ports": {
        "game": $game_port,
        "query": $query_port,
        "rcon": $rcon_port
    },
    "preset_file": "config/presets/${context}.env",
    "docker_image": "palworld-enhanced:latest",
    "extraction_method": "docker_volume"
}
META_EOF
    
    # Create tar archive
    (cd "$temp_dir" && tar -czf "$backup_file" .)
    
    if [[ $? -eq 0 ]]; then
        local backup_size=$(du -sh "$backup_file" | cut -f1)
        log_success "Backup created successfully: $backup_size"
        log_info "Backup file: $backup_file"
        log_info "Metadata file: $meta_file"
    else
        log_error "Failed to create backup archive"
        docker rm -f "$temp_container" >/dev/null 2>&1
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    docker rm -f "$temp_container" >/dev/null 2>&1
    rm -rf "$temp_dir"
    
    echo "$backup_file"  # Return backup file path for caller
}

# List available contexts and their volumes
list_volumes() {
    log_info "Docker volumes for Palworld servers:"
    docker volume ls | grep "palworld-vol-" | while read driver volume_name; do
        local temp="${volume_name#palworld-}"
        local context="${volume_name#palworld-vol-}"
        local size=$(docker run --rm -v "$volume_name:/data" ubuntu:22.04 du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
        echo "  $context: $volume_name ($size)"
    done
}

# Main command handling
case "${1:-help}" in
    "inject")
        inject_world_data "$2" "$3"
        ;;
    "extract")
        extract_world_data "$2" "$3"
        ;;
    "list-volumes")
        list_volumes
        ;;
    "ports")
        if [[ -n "$2" ]]; then
            ports=($(get_port_assignments "$2"))
            echo "Context: $2"
            echo "Game Port: ${ports[0]}"
            echo "Query Port: ${ports[1]}"
            echo "RCON Port: ${ports[2]}"
            echo "REST API Port: 9999"
        else
            log_error "Usage: $0 ports <context>"
        fi
        ;;
    *)
        echo "World Manager - Palworld Multi-Server Data Management"
        echo
        echo "USAGE:"
        echo "  $0 inject <context> <backup_file>     Inject world data from backup into volume"
        echo "  $0 extract <context> [backup_name]    Extract world data from volume to backup"
        echo "  $0 list-volumes                       List all server volumes"
        echo "  $0 ports <context>                    Show port assignments for context"
        echo
        echo "EXAMPLES:"
        echo "  $0 inject tournament tournament_pvp_20260315_120000.tar.gz"
        echo "  $0 extract hardcore"
        echo "  $0 list-volumes"
        echo "  $0 ports tournament"
        ;;
esac
