#!/bin/bash

# Universal Game Server Manager - Game-agnostic server orchestrator
# Delegates to game-specific plugins while providing common infrastructure

# Script directory detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source shared utilities and plugin system
source "${SCRIPT_DIR}/../shared/server-utils.sh"
source "${SCRIPT_DIR}/../shared/game-plugins.sh"

# Usage display
usage() {
    echo "Universal Game Server Manager"
    echo
    echo "USAGE:"
    echo "  $0 <operation> --game <game> --instance <instance> --env <environment> [options]"
    echo
    echo "OPERATIONS:"
    echo "  start         Start a game server"
    echo "  stop          Stop a game server"
    echo "  restart       Restart a game server"
    echo "  status        Show server status"
    echo "  health        Check server health"
    echo "  list          List running servers"
    echo "  backup        Create backup of server data"
    echo "  restore       Restore server from backup"
    echo "  list-backups  List available backups"
    echo "  validate      Validate game plugin"
    echo
    echo "REQUIRED FLAGS:"
    echo "  --game <name>         Game to manage (palworld, valheim, minecraft, etc.)"
    echo "  --instance <name>     Server instance name (main, backup, test, etc.)"
    echo "  --env <environment>   Environment (staging, production)"
    echo
    echo "OPTIONAL FLAGS:"
    echo "  --backup <file>       Backup file for restore during start"
    echo "  --preset <name>       Preset name for configuration"
    echo "  --dry-run            Test mode - validate without executing"
    echo "  --force              Skip safety confirmations"
    echo
    echo "EXAMPLES:"
    echo "  $0 start --game palworld --instance main --env production --preset tournament"
    echo "  $0 stop --game palworld --instance main --env production"
    echo "  $0 restart --game palworld --instance main --env production --preset casual"
    echo "  $0 backup --game palworld --instance main --env production"
    echo "  $0 restore --game palworld --instance test --env staging --backup tournament_main_20240322.tar.gz"
    echo "  $0 list-backups --game palworld --instance main --env production"
    echo
    echo "SUPPORTED GAMES:"
    if command -v jq >/dev/null 2>&1; then
        for game_dir in "${REPO_ROOT}"/games/*/; do
            local game=$(basename "$game_dir")
            echo "  $game"
        done
    else
        echo "  (Check games/ directory for supported games)"
    fi
}

# Parse command line arguments
parse_arguments() {
    OPERATION=""
    GAME=""
    INSTANCE=""
    ENVIRONMENT=""
    BACKUP_FILE=""
    PRESET=""
    DRY_RUN=false
    FORCE=false
    
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi
    
    OPERATION="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --game)
                GAME="$2"
                shift 2
                ;;
            --instance)
                INSTANCE="$2"
                shift 2
                ;;
            --env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --backup)
                BACKUP_FILE="$2"
                shift 2
                ;;
            --preset)
                PRESET="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate required arguments based on operation
    case "$OPERATION" in
        start|stop|restart|health|status|backup)
            if [[ -z "$GAME" || -z "$INSTANCE" || -z "$ENVIRONMENT" ]]; then
                log_error "Operation '$OPERATION' requires --game, --instance, and --env"
                exit 1
            fi
            ;;
        restore|list-backups)
            if [[ -z "$GAME" || -z "$INSTANCE" || -z "$ENVIRONMENT" ]]; then
                log_error "Operation '$OPERATION' requires --game, --instance, and --env"
                exit 1
            fi
            if [[ "$OPERATION" == "restore" && -z "$BACKUP_FILE" ]]; then
                log_error "Restore operation requires --backup <file>"
                exit 1
            fi
            ;;
        list)
            if [[ -z "$GAME" || -z "$ENVIRONMENT" ]]; then
                log_error "Operation '$OPERATION' requires --game and --env"
                exit 1
            fi
            ;;
        validate)
            if [[ -z "$GAME" || -z "$ENVIRONMENT" ]]; then
                log_error "Operation '$OPERATION' requires --game and --env"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown operation: $OPERATION"
            usage
            exit 1
            ;;
    esac
}

# Start server operation
start_server() {
    log_info "Starting server: $GAME-$INSTANCE-$ENVIRONMENT"
    
    # Run safety checklist
    if ! run_safety_checklist "start" "$GAME" "$INSTANCE" "$ENVIRONMENT"; then
        return 1
    fi
    
    # Safety confirmation (unless forced)
    if [[ "$FORCE" != true ]]; then
        local additional_info=""
        if [[ -n "$BACKUP_FILE" ]]; then
            additional_info="Will restore from backup: $BACKUP_FILE"
        fi
        if ! safety_confirmation "start server" "$GAME" "$INSTANCE" "$ENVIRONMENT" "$additional_info"; then
            return 1
        fi
    fi
    
    # Create emergency backup if volume exists
    local volume_name=$(get_volume_name "$GAME" "$INSTANCE" "$ENVIRONMENT")
    if volume_exists "$volume_name"; then
        if [[ "$DRY_RUN" != true ]]; then
            create_emergency_backup "start" "$GAME" "$INSTANCE" "$ENVIRONMENT"
        else
            log_info "[DRY-RUN] Would create emergency backup"
        fi
    fi
    
    # Load game plugin and call start function
    if ! load_game_plugin "$GAME" "$ENVIRONMENT"; then
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would call: ${GAME}_start_server $INSTANCE $ENVIRONMENT $BACKUP_FILE $PRESET"
        return 0
    fi
    
    # Call the game-specific start function
    call_plugin_function "$GAME" "start_server" "$INSTANCE" "$ENVIRONMENT" "$BACKUP_FILE" "$PRESET"
}

# Stop server operation
stop_server() {
    log_info "Stopping server: $GAME-$INSTANCE-$ENVIRONMENT"
    
    # Check if container exists
    local container_name=$(get_container_name "$GAME" "$INSTANCE" "$ENVIRONMENT")
    if ! container_exists "$container_name"; then
        log_warning "Container does not exist: $container_name"
        return 0
    fi
    
    # Safety confirmation (unless forced)
    if [[ "$FORCE" != true ]]; then
        if ! safety_confirmation "stop server" "$GAME" "$INSTANCE" "$ENVIRONMENT"; then
            return 1
        fi
    fi
    
    # Load game plugin and call stop function
    if ! load_game_plugin "$GAME" "$ENVIRONMENT"; then
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would call: ${GAME}_stop_server $INSTANCE $ENVIRONMENT"
        return 0
    fi
    
    # Call the game-specific stop function
    call_plugin_function "$GAME" "stop_server" "$INSTANCE" "$ENVIRONMENT"
}

# Restart server operation
restart_server() {
    log_info "Restarting server: $GAME-$INSTANCE-$ENVIRONMENT"
    
    # Load game plugin
    if ! load_game_plugin "$GAME" "$ENVIRONMENT"; then
        return 1
    fi
    
    # Check if restart function exists, otherwise use stop + start
    if plugin_function_exists "$GAME" "restart_server"; then
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would call: ${GAME}_restart_server $INSTANCE $ENVIRONMENT"
            return 0
        fi
        call_plugin_function "$GAME" "restart_server" "$INSTANCE" "$ENVIRONMENT"
    else
        log_info "No restart function found, using stop + start"
        if stop_server && sleep 5; then
            start_server
        else
            return 1
        fi
    fi
}

# Health check operation
health_check() {
    log_info "Checking health: $GAME-$INSTANCE-$ENVIRONMENT"
    
    # Load game plugin and call health check function
    if ! load_game_plugin "$GAME" "$ENVIRONMENT"; then
        return 1
    fi
    
    call_plugin_function "$GAME" "health_check" "$INSTANCE" "$ENVIRONMENT"
}

# Status operation
show_status() {
    log_info "Server status: $GAME-$INSTANCE-$ENVIRONMENT"
    
    local container_name=$(get_container_name "$GAME" "$INSTANCE" "$ENVIRONMENT")
    local volume_name=$(get_volume_name "$GAME" "$INSTANCE" "$ENVIRONMENT")
    
    echo
    echo "=== Server Status ==="
    echo "Game: $GAME"
    echo "Instance: $INSTANCE"
    echo "Environment: $ENVIRONMENT"
    echo "Container: $container_name"
    echo "Volume: $volume_name"
    echo
    
    # Container status
    if container_exists "$container_name"; then
        if container_running "$container_name"; then
            echo "Container Status: Running"
            
            # Get port information
            local ports=($(get_port_assignments "$GAME" "$INSTANCE" "$ENVIRONMENT"))
            echo "Ports: Game=${ports[0]}, Query=${ports[1]}, RCON=${ports[2]}, API=${ports[3]}"
            
            # Show container details
            echo
            echo "Container Details:"
            docker ps --filter name="$container_name" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            
        else
            echo "Container Status: Stopped"
        fi
    else
        echo "Container Status: Does not exist"
    fi
    
    # Volume status
    echo
    if volume_exists "$volume_name"; then
        local volume_size=$(docker run --rm -v "$volume_name:/data" ubuntu:22.04 du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
        echo "Volume Status: Exists ($volume_size)"
    else
        echo "Volume Status: Does not exist"
    fi
    
    # Run health check if container is running
    if container_running "$container_name"; then
        echo
        echo "=== Health Check ==="
        health_check
    fi
}

# List servers operation
list_servers() {
    log_info "Listing $GAME servers in $ENVIRONMENT environment"
    
    echo
    echo "=== $GAME Servers ($ENVIRONMENT) ==="
    
    # Find all containers matching the pattern
    local pattern="${GAME}-${ENVIRONMENT}-"
    local containers=$(docker ps -a --format "{{.Names}}" | grep "^${pattern}" || true)
    
    if [[ -z "$containers" ]]; then
        echo "No $GAME servers found in $ENVIRONMENT environment"
        return 0
    fi
    
    echo
    printf "%-20s %-15s %-10s %-15s\n" "CONTEXT" "STATUS" "PORTS" "VOLUME_SIZE"
    printf "%-20s %-15s %-10s %-15s\n" "--------" "------" "-----" "-----------"
    
    while read -r container_name; do
        local context="${container_name#${pattern}}"
        local volume_name=$(get_volume_name "$GAME" "$context" "$ENVIRONMENT")
        
        local status="stopped"
        if container_running "$container_name"; then
            status="running"
        fi
        
        local ports=($(get_port_assignments "$GAME" "$context" "$ENVIRONMENT"))
        local main_port="${ports[0]}"
        
        local volume_size="none"
        if volume_exists "$volume_name"; then
            volume_size=$(docker run --rm -v "$volume_name:/data" ubuntu:22.04 du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
        fi
        
        printf "%-20s %-15s %-10s %-15s\n" "$context" "$status" "$main_port" "$volume_size"
        
    done <<< "$containers"
}

# Backup server operation
backup_server() {
    log_info "Creating backup: $GAME-$INSTANCE-$ENVIRONMENT"
    
    # Check if container exists and is running
    local container_name=$(get_container_name "$GAME" "$INSTANCE" "$ENVIRONMENT")
    if ! container_exists "$container_name"; then
        log_error "Container does not exist: $container_name"
        return 1
    fi
    
    if ! container_running "$container_name"; then
        log_warning "Container is not running: $container_name"
    fi
    
    # Safety confirmation (unless forced)
    if [[ "$FORCE" != true ]]; then
        if ! safety_confirmation "create backup" "$GAME" "$INSTANCE" "$ENVIRONMENT"; then
            return 1
        fi
    fi
    
    # Load game plugin and call backup function
    if ! load_game_plugin "$GAME" "$ENVIRONMENT"; then
        return 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would call: ${GAME}_backup_data $INSTANCE $ENVIRONMENT"
        return 0
    fi
    
    # Call the game-specific backup function
    call_plugin_function "$GAME" "backup_data" "$INSTANCE" "$ENVIRONMENT"
}

# List backups operation
list_backups() {
    log_info "Listing backups: $GAME-$INSTANCE-$ENVIRONMENT"
    
    local backup_dir="${REPO_ROOT}/backups/$ENVIRONMENT/$INSTANCE"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_warning "No backup directory found: $backup_dir"
        return 0
    fi
    
    echo
    echo "=== Backups for $GAME-$INSTANCE ($ENVIRONMENT) ==="
    echo
    
    local backups=($(find "$backup_dir" -name "*.tar.gz" -type f | sort -r))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backups found in $backup_dir"
        return 0
    fi
    
    printf "%-40s %-12s %-20s %-15s\n" "BACKUP NAME" "SIZE" "CREATED" "WORLD ID"
    printf "%-40s %-12s %-20s %-15s\n" "-----------" "----" "-------" "--------"
    
    for backup in "${backups[@]}"; do
        local basename="$(basename "$backup")"
        local size=$(du -sh "$backup" | cut -f1)
        local meta_file="${backup%%.tar.gz}.meta.json"
        
        local created="unknown"
        local world_id="unknown"
        
        if [[ -f "$meta_file" ]]; then
            created=$(jq -r '.timestamp // "unknown"' "$meta_file" 2>/dev/null | cut -dT -f1)
            world_id=$(jq -r '.world_id // "unknown"' "$meta_file" 2>/dev/null)
        fi
        
        printf "%-40s %-12s %-20s %-15s\n" "$basename" "$size" "$created" "$world_id"
    done
}

# Validate game plugin
validate_plugin() {
    log_info "Validating plugin: $GAME ($ENVIRONMENT)"
    
    if validate_game_plugin "$GAME" "$ENVIRONMENT"; then
        log_success "Plugin validation successful for: $GAME"
        
        echo
        echo "Available operations for $GAME:"
        list_game_operations "$GAME" "$ENVIRONMENT" | sed 's/^/  /'
        
        return 0
    else
        log_error "Plugin validation failed for: $GAME"
        return 1
    fi
}

# Main execution
main() {
    parse_arguments "$@"
    
    # Validate naming conventions
    if [[ -n "$GAME" ]] && ! validate_naming_convention "$GAME" "game"; then
        exit 1
    fi
    
    if [[ -n "$INSTANCE" ]] && ! validate_naming_convention "$INSTANCE" "instance"; then
        exit 1
    fi
    
    # Execute operation
    case "$OPERATION" in
        start)
            start_server
            ;;
        stop)
            stop_server
            ;;
        restart)
            restart_server
            ;;
        health)
            health_check
            ;;
        status)
            show_status
            ;;
        list)
            list_servers
            ;;
        backup)
            backup_server
            ;;
        list-backups)
            list_backups
            ;;
        validate)
            validate_plugin
            ;;
        *)
            log_error "Unknown operation: $OPERATION"
            usage
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi