#!/bin/bash

# Multi-Server Container Management for Palworld
# Handles multiple concurrent server instances with artifact-based world injection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORLD_MANAGER="$SCRIPT_DIR/world-manager.sh"
COMPOSE_TEMPLATE="$SCRIPT_DIR/docker-compose.template.yml"

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

# Generate context-specific docker-compose file
generate_compose_file() {
    local context="$1"
    
    if [[ -z "$context" ]]; then
        log_error "Context required for compose file generation"
        return 1
    fi
    
    if [[ ! -f "$COMPOSE_TEMPLATE" ]]; then
        log_error "Docker compose template not found: $COMPOSE_TEMPLATE"
        return 1
    fi
    
    # Get port assignments
    local game_port=$("$WORLD_MANAGER" ports "$context" | grep "Game Port:" | cut -d: -f2 | tr -d " ")
    local query_port=$("$WORLD_MANAGER" ports "$context" | grep "Query Port:" | cut -d: -f2 | tr -d " ")
    local rcon_port=$("$WORLD_MANAGER" ports "$context" | grep "RCON Port:" | cut -d: -f2 | tr -d " ")
    local restapi_port=$(./world-manager.sh ports "$context" | grep "REST API Port:" | cut -d: -f2 | tr -d " ")
    local game_port="$game_port"
    local query_port="$query_port"
    local rcon_port="$rcon_port"
    local restapi_port=$(./world-manager.sh ports "$context" | grep "REST API Port:" | cut -d: -f2 | tr -d " ")
    
    local compose_file="docker-compose-${context}.yml"
    
    # Generate compose file from template
    CONTEXT="$context" \
    GAME_PORT="$game_port" \
    QUERY_PORT="$query_port" \
    RCON_PORT="$rcon_port" \
    RESTAPI_PORT="$restapi_port" \
    envsubst < "$COMPOSE_TEMPLATE" > "$compose_file"
    
    log_info "Generated compose file: $compose_file" >&2
    log_info "Ports: Game=$game_port, Query=$query_port, RCON=$rcon_port, REST API=$restapi_port" >&2
    
    echo "$compose_file"
}

# Start server with context
start_server() {
    local context="$1"
    local backup_file="$2"
    
    if [[ -z "$context" ]]; then
        log_error "Usage: start_server <context> [backup_file]"
        return 1
    fi
    
    # Check if preset exists
    if [[ ! -f "config/presets/${context}.env" ]]; then
        log_error "Preset not found: config/presets/${context}.env"
        log_info "Available presets:"
        ls -1 config/presets/*.env 2>/dev/null | xargs -I {} basename {} .env | sed 's/^/  /'
        return 1
    fi
    
    # Check if server is already running
    if docker ps --format "{{.Names}}" | grep -q "^palworld-${context}$"; then
        log_warning "Server already running: palworld-${context}"
        return 1
    fi
    
    log_info "Starting server: $context"
    
    # Generate compose file
    local compose_file=$(generate_compose_file "$context")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # If backup file specified, inject world data first
    if [[ -n "$backup_file" ]]; then
        log_info "Injecting world data from backup: $backup_file"
        
        # Find backup file if not full path
        if [[ ! -f "$backup_file" ]]; then
            local found_backup=""
            for search_path in "backups/${context}/${backup_file}" "backups/*/${backup_file}" "$backup_file"; do
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
        
        # Inject world data
        local world_id=$("$WORLD_MANAGER" inject "$context" "$backup_file")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to inject world data"
            return 1
        fi
        
        log_success "World data injected successfully (World ID: $world_id)"
    fi
    
    # Start server using generated compose file
    docker compose -p "palworld-${context}" -f "$compose_file" up -d
    
    if [[ $? -eq 0 ]]; then
        log_success "Server started: palworld-${context}"
        
        # Show server info
        local game_port=$("$WORLD_MANAGER" ports "$context" | grep "Game Port:" | cut -d: -f2 | tr -d " ")
    local query_port=$("$WORLD_MANAGER" ports "$context" | grep "Query Port:" | cut -d: -f2 | tr -d " ")
    local rcon_port=$("$WORLD_MANAGER" ports "$context" | grep "RCON Port:" | cut -d: -f2 | tr -d " ")
    local restapi_port=$(./world-manager.sh ports "$context" | grep "REST API Port:" | cut -d: -f2 | tr -d " ")
        echo
        echo "Server Information:"
        echo "  Context: $context"
        echo "  Container: palworld-${context}"
        echo "  Game Port: $game_port"
        echo "  Query Port: $query_port"
        echo "  RCON Port: $rcon_port"
        echo "  Preset: config/presets/${context}.env"
        
        if [[ -n "$backup_file" ]]; then
            echo "  Restored from: $(basename "$backup_file")"
        fi
        
        return 0
    else
        log_error "Failed to start server: $context"
        return 1
    fi
}

# Stop server with context
stop_server() {
    local context="$1"
    
    if [[ -z "$context" ]]; then
        log_error "Usage: stop_server <context>"
        return 1
    fi
    
    local compose_file="docker-compose-${context}.yml"
    
    if [[ ! -f "$compose_file" ]]; then
        log_warning "Compose file not found: $compose_file"
        log_info "Attempting to stop container directly..."
        docker stop "palworld-${context}" 2>/dev/null
        docker rm "palworld-${context}" 2>/dev/null
        return $?
    fi
    
    log_info "Stopping server: $context"
    
    # Stop server using compose file
    docker compose -p "palworld-${context}" -f "$compose_file" down
    
    if [[ $? -eq 0 ]]; then
        log_success "Server stopped: palworld-${context}"
        
        # Optionally remove compose file
        read -p "Remove compose file? [y/N]: " -r remove_compose
        case $remove_compose in
            [Yy]*)
                rm -f "$compose_file"
                log_info "Removed compose file: $compose_file"
                ;;
        esac
        
        return 0
    else
        log_error "Failed to stop server: $context"
        return 1
    fi
}

# List all running servers
list_servers() {
    log_info "Palworld Multi-Server Status:"
    echo
    
    # Get all palworld containers
    local containers=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "^palworld-")
    
    if [[ -z "$containers" ]]; then
        echo "  No servers currently running"
        return 0
    fi
    
    echo "Running Servers:"
    echo "$containers" | while IFS=$'\t' read -r name status ports; do
        local context="${name#palworld-}"
        local game_port=$(echo "$ports" | grep -o '0\.0\.0\.0:[0-9]*->8215' | cut -d: -f2 | cut -d- -f1)
        echo "  ├─ $context"
        echo "  │  Container: $name"
        echo "  │  Status: $status"
        echo "  │  Game Port: $game_port"
        echo "  │  Preset: config/presets/${context}.env"
        echo "  └─"
    done
    
    # Show available compose files
    echo
    echo "Available Compose Files:"
    for compose_file in docker-compose-*.yml; do
        if [[ -f "$compose_file" ]]; then
            local context="${compose_file#docker-compose-}"
            context="${context%.yml}"
            echo "  $context: $compose_file"
        fi
    done
    
    # Show volumes
    echo
    "$WORLD_MANAGER" list-volumes
}

# Restart server with context
restart_server() {
    local context="$1"
    
    if [[ -z "$context" ]]; then
        log_error "Usage: restart_server <context>"
        return 1
    fi
    
    log_info "Restarting server: $context"
    
    # Check if server is running
    if ! docker ps --format "{{.Names}}" | grep -q "^palworld-${context}$"; then
        log_warning "Server not currently running: $context"
        log_info "Starting server instead..."
        start_server "$context"
        return $?
    fi
    
    local compose_file="docker-compose-${context}.yml"
    
    if [[ -f "$compose_file" ]]; then
        docker compose -f "$compose_file" restart
    else
        docker restart "palworld-${context}"
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Server restarted: palworld-${context}"
        return 0
    else
        log_error "Failed to restart server: $context"
        return 1
    fi
}

# Show logs for a specific server
show_logs() {
    local context="$1"
    local lines="${2:-50}"
    
    if [[ -z "$context" ]]; then
        log_error "Usage: show_logs <context> [lines]"
        return 1
    fi
    
    local container_name="palworld-${context}"
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        log_error "Server not running: $context"
        return 1
    fi
    
    log_info "Showing logs for: $context (last $lines lines)"
    echo
    docker logs "$container_name" --tail "$lines" --timestamps
}

# Main command handling
case "${1:-help}" in
    "start")
        start_server "$2" "$3"
        ;;
    "stop")
        stop_server "$2"
        ;;
    "restart")
        restart_server "$2"
        ;;
    "list"|"ls")
        list_servers
        ;;
    "logs")
        show_logs "$2" "$3"
        ;;
    "generate-compose")
        generate_compose_file "$2"
        ;;
    *)
        echo "Multi-Server Manager - Palworld Concurrent Server Management"
        echo
        echo "USAGE:"
        echo "  $0 start <context> [backup_file]      Start server with optional world restore"
        echo "  $0 stop <context>                     Stop server"
        echo "  $0 restart <context>                  Restart server"
        echo "  $0 list                               List all running servers"
        echo "  $0 logs <context> [lines]             Show server logs"
        echo "  $0 generate-compose <context>         Generate compose file for context"
        echo
        echo "EXAMPLES:"
        echo "  $0 start tournament                           # Start fresh tournament server"
        echo "  $0 start hardcore hardcore_pvp_20260315.tar.gz  # Start with world restore"
        echo "  $0 stop tournament                            # Stop tournament server"
        echo "  $0 list                                       # Show all servers"
        echo "  $0 logs hardcore 100                          # Show last 100 log lines"
        echo
        echo "AVAILABLE CONTEXTS:"
        if [[ -d "config/presets" ]]; then
            ls -1 config/presets/*.env 2>/dev/null | xargs -I {} basename {} .env | sed 's/^/  /'
        else
            echo "  No presets found in config/presets/"
        fi
        ;;
esac
