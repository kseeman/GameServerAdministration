#!/bin/bash
set -euo pipefail

# Game Server Rollback Script
# Reverts failed deployments to previous working state

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

# Default values
ENVIRONMENT=""
GAME=""
CONTEXT=""
BACKUP_ID=""
AUTO_CONFIRM=false
DRY_RUN=false
SKIP_HEALTH_CHECK=false

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Rollback game server deployment to previous working state

OPTIONS:
    --env ENV           Environment: staging or production (required)
    --game GAME         Game type (required)
    --context CONTEXT   Server context (required)
    --backup-id ID      Specific backup ID to rollback to (optional)
    --auto-confirm     Skip rollback confirmation prompt
    --dry-run          Show what would be rolled back without executing
    --skip-health      Skip post-rollback health checks
    -h, --help         Show this help message

EXAMPLES:
    # Rollback to latest backup
    $0 --env staging --game palworld --context tournament

    # Rollback to specific backup
    $0 --env production --game palworld --context main --backup-id 20240322-151234

    # Automatic rollback (no prompts)
    $0 --env staging --game palworld --context test --auto-confirm

    # Dry run rollback
    $0 --env staging --game palworld --context test --dry-run

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --game)
                GAME="$2"
                shift 2
                ;;
            --context)
                CONTEXT="$2"
                shift 2
                ;;
            --backup-id)
                BACKUP_ID="$2"
                shift 2
                ;;
            --auto-confirm)
                AUTO_CONFIRM=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH_CHECK=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$ENVIRONMENT" || -z "$GAME" || -z "$CONTEXT" ]]; then
        log_error "Missing required arguments"
        show_usage
        exit 1
    fi
}

validate_rollback_environment() {
    log_info "Validating rollback environment..."
    
    # Check if game environment config exists
    local config=$(get_game_env_config "$GAME" "$ENVIRONMENT")
    if [[ ! -f "$config" ]]; then
        log_error "Game environment config not found: $config"
        exit 1
    fi

    # Validate game and context through registry
    if ! validate_game_context "$GAME" "$CONTEXT" "$ENVIRONMENT"; then
        log_error "Invalid game/context combination for environment: $ENVIRONMENT"
        exit 1
    fi

    log_info "Rollback environment validation passed"
}

list_available_backups() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    local volume_name="${GAME}-vol-${ENVIRONMENT}-${CONTEXT}"
    
    log_info "Listing available backups for $server_name..."
    
    # List backups using server-manager
    if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" list-backups --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT"; then
        log_error "Failed to list available backups"
        return 1
    fi
}

select_backup_to_restore() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ -n "$BACKUP_ID" ]]; then
        log_info "Using specified backup ID: $BACKUP_ID"
        return 0
    fi
    
    log_info "No backup ID specified, selecting latest backup..."
    
    # Get latest backup from server-manager
    local latest_backup
    latest_backup=$("$PROJECT_ROOT/scripts/core/server-manager.sh" list-backups --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --latest 2>/dev/null | head -1 || echo "")
    
    if [[ -z "$latest_backup" ]]; then
        log_error "No backups available for rollback"
        exit 1
    fi
    
    BACKUP_ID="$latest_backup"
    log_info "Selected latest backup: $BACKUP_ID"
}

confirm_rollback() {
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        log_info "Auto-confirm enabled, skipping confirmation prompt"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run mode, skipping confirmation prompt"
        return 0
    fi
    
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    log_warn "=== ROLLBACK CONFIRMATION ==="
    log_warn "Server: $server_name"
    log_warn "Environment: $ENVIRONMENT"
    log_warn "Backup ID: $BACKUP_ID"
    log_warn ""
    log_warn "This will:"
    log_warn "1. Stop the current server"
    log_warn "2. Replace current data with backup data"
    log_warn "3. Restart the server with restored data"
    log_warn ""
    log_warn "⚠️  Any changes made since the backup was created WILL BE LOST"
    log_warn "=========================="
    
    echo
    read -p "Type '${GAME}-${CONTEXT}' to confirm rollback: " confirmation
    
    if [[ "$confirmation" != "${GAME}-${CONTEXT}" ]]; then
        log_error "Rollback cancelled - confirmation text did not match"
        exit 1
    fi
    
    log_info "Rollback confirmed"
}

check_current_server_status() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    log_info "Checking current server status: $server_name"
    
    # Use server-manager to check status
    if "$PROJECT_ROOT/scripts/core/server-manager.sh" status --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --quiet 2>/dev/null; then
        log_info "Server is currently running"
        return 0
    else
        log_info "Server is not running"
        return 1
    fi
}

create_emergency_backup() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    log_info "Creating emergency backup before rollback..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create emergency backup of $server_name"
        return 0
    fi

    # Create emergency backup using server-manager
    if "$PROJECT_ROOT/scripts/core/server-manager.sh" backup --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --tag "pre-rollback" --quiet; then
        log_info "Emergency backup created successfully"
    else
        log_error "Failed to create emergency backup"
        log_error "Rollback aborted for safety"
        exit 1
    fi
}

perform_rollback() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    log_info "Starting rollback for server: $server_name"
    log_info "Rolling back to backup: $BACKUP_ID"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Rollback steps that would be executed:"
        log_info "[DRY RUN] 1. Stop current server (if running)"
        log_info "[DRY RUN] 2. Restore data from backup: $BACKUP_ID"
        log_info "[DRY RUN] 3. Start server with restored data"
        log_info "[DRY RUN] 4. Run health checks (unless --skip-health specified)"
        return 0
    fi

    # Check if server is running and stop it
    local server_was_running=false
    if check_current_server_status; then
        server_was_running=true
        
        log_info "Stopping server for rollback..."
        if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" stop --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT"; then
            log_error "Failed to stop server for rollback"
            exit 1
        fi
    fi

    # Restore from backup using server-manager
    log_info "Restoring from backup: $BACKUP_ID"
    if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" restore --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --backup-id "$BACKUP_ID"; then
        log_error "Failed to restore from backup"
        
        # If server was running, try to restart it with current data
        if [[ "$server_was_running" == "true" ]]; then
            log_error "Attempting to restart server with current data..."
            "$PROJECT_ROOT/scripts/core/server-manager.sh" start --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" || true
        fi
        exit 1
    fi

    # Start the server with restored data
    log_info "Starting server with restored data..."
    if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" start --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT"; then
        log_error "Failed to start server after rollback"
        log_error "Server is in an unknown state - manual intervention may be required"
        exit 1
    fi

    log_info "Server rollback completed successfully"
}

run_post_rollback_health_checks() {
    if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
        log_info "Skipping health checks as requested"
        return 0
    fi

    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    log_info "Running post-rollback health checks..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run health checks for $server_name"
        return 0
    fi

    # Run health check script
    if "$PROJECT_ROOT/scripts/deployment/health-check.sh" --env "$ENVIRONMENT" --game "$GAME" --context "$CONTEXT"; then
        log_info "Health checks passed"
    else
        log_error "Health checks failed"
        log_error "Rollback may have issues - check server logs"
        return 1
    fi
}

show_rollback_summary() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    log_info "=== Rollback Summary ==="
    log_info "Server: $server_name"
    log_info "Environment: $ENVIRONMENT"
    log_info "Backup ID: $BACKUP_ID"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Status: Rolled Back"
        
        # Show current server status
        log_info "Current server status:"
        "$PROJECT_ROOT/scripts/core/server-manager.sh" status --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" || true
    else
        log_info "Status: Dry run completed"
    fi
    
    log_info "====================="
}

main() {
    log_info "Starting game server rollback..."
    
    parse_arguments "$@"
    validate_rollback_environment
    
    # List available backups
    list_available_backups
    
    # Select backup to restore
    select_backup_to_restore
    
    # Confirm rollback
    confirm_rollback
    
    # Create emergency backup before rollback (skip in dry run)
    if [[ "$DRY_RUN" == "false" ]]; then
        create_emergency_backup
    fi
    
    # Perform rollback
    perform_rollback
    
    # Run health checks
    run_post_rollback_health_checks
    
    # Show summary
    show_rollback_summary
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run completed successfully"
    else
        log_info "Rollback completed successfully"
    fi
}

# Run main function with all arguments
main "$@"