#!/bin/bash
set -euo pipefail

# Game Server Deployment Script
# Orchestrates deployment of game servers to staging or production environments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

# Default values
ENVIRONMENT=""
GAME=""
CONTEXT=""
PRESET_FILE=""
DRY_RUN=false
SKIP_HEALTH_CHECK=false
FORCE_RESTART=false

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy game servers to staging or production environments

OPTIONS:
    --env ENV           Environment: staging or production (required)
    --game GAME         Game type (required)
    --context CONTEXT   Server context (required)
    --preset FILE       Preset configuration file (required)
    --dry-run          Show what would be deployed without executing
    --skip-health      Skip post-deployment health checks
    --force-restart    Force restart even if server is healthy
    -h, --help         Show this help message

EXAMPLES:
    # Deploy to staging
    $0 --env staging --game palworld --context tournament --preset tournament.json

    # Deploy to production with health checks
    $0 --env production --game palworld --context main --preset main-server.json

    # Dry run deployment
    $0 --env staging --game palworld --context test --preset test.json --dry-run

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
            --preset)
                PRESET_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH_CHECK=true
                shift
                ;;
            --force-restart)
                FORCE_RESTART=true
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
    if [[ -z "$ENVIRONMENT" || -z "$GAME" || -z "$CONTEXT" || -z "$PRESET_FILE" ]]; then
        log_error "Missing required arguments"
        show_usage
        exit 1
    fi
}

validate_deployment_environment() {
    log_info "Validating deployment environment..."
    
    # Check if environment exists
    if [[ ! -d "$PROJECT_ROOT/environments/$ENVIRONMENT" ]]; then
        log_error "Environment not found: $ENVIRONMENT"
        exit 1
    fi

    # Check if preset file exists
    local preset_path="$PROJECT_ROOT/environments/$ENVIRONMENT/presets/$GAME/$PRESET_FILE"
    if [[ ! -f "$preset_path" ]]; then
        log_error "Preset file not found: $preset_path"
        exit 1
    fi

    # Validate game and context through registry
    if ! validate_game_context "$GAME" "$CONTEXT" "$ENVIRONMENT"; then
        log_error "Invalid game/context combination for environment: $ENVIRONMENT"
        exit 1
    fi

    log_info "Deployment environment validation passed"
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

backup_current_deployment() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    log_info "Creating backup of current deployment..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create backup of $server_name"
        return 0
    fi

    # Create backup using server-manager
    if "$PROJECT_ROOT/scripts/core/server-manager.sh" backup --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --quiet; then
        log_info "Backup created successfully"
    else
        log_error "Failed to create backup"
        exit 1
    fi
}

deploy_server() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    local preset_path="$PROJECT_ROOT/environments/$ENVIRONMENT/presets/$GAME/$PRESET_FILE"
    
    log_info "Deploying server: $server_name"
    log_info "Using preset: $PRESET_FILE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Deployment steps that would be executed:"
        log_info "[DRY RUN] 1. Stop existing server (if running)"
        log_info "[DRY RUN] 2. Apply configuration from $preset_path"
        log_info "[DRY RUN] 3. Start server with new configuration"
        log_info "[DRY RUN] 4. Run health checks (unless --skip-health specified)"
        return 0
    fi

    # Check if server is running and needs restart
    local server_running=false
    if check_current_server_status; then
        server_running=true
        
        if [[ "$FORCE_RESTART" == "false" ]]; then
            log_info "Server is already running. Use --force-restart to restart anyway."
            log_info "Checking if configuration update is needed..."
            
            # For now, we'll restart on any deployment. In future, could add config diff checking
            log_info "Configuration deployment requires server restart"
        fi
        
        log_info "Stopping server for deployment..."
        if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" stop --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT"; then
            log_error "Failed to stop server for deployment"
            exit 1
        fi
    fi

    # Apply preset configuration and start server
    log_info "Starting server with new configuration..."
    if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" start --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --preset "$PRESET_FILE"; then
        log_error "Failed to start server with new configuration"
        
        # Attempt rollback if we had a running server
        if [[ "$server_running" == "true" ]]; then
            log_error "Attempting to rollback deployment..."
            "$PROJECT_ROOT/scripts/deployment/rollback.sh" --env "$ENVIRONMENT" --game "$GAME" --context "$CONTEXT" --auto-confirm
        fi
        exit 1
    fi

    log_info "Server started successfully"
}

run_health_checks() {
    if [[ "$SKIP_HEALTH_CHECK" == "true" ]]; then
        log_info "Skipping health checks as requested"
        return 0
    fi

    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    log_info "Running post-deployment health checks..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run health checks for $server_name"
        return 0
    fi

    # Run health check script
    if "$PROJECT_ROOT/scripts/deployment/health-check.sh" --env "$ENVIRONMENT" --game "$GAME" --context "$CONTEXT"; then
        log_info "Health checks passed"
    else
        log_error "Health checks failed"
        log_error "Deployment may have issues - check server logs"
        return 1
    fi
}

show_deployment_summary() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    log_info "=== Deployment Summary ==="
    log_info "Environment: $ENVIRONMENT"
    log_info "Game: $GAME"
    log_info "Context: $CONTEXT"
    log_info "Server Name: $server_name"
    log_info "Preset: $PRESET_FILE"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        log_info "Status: Deployed"
        
        # Show current server status
        log_info "Current server status:"
        "$PROJECT_ROOT/scripts/core/server-manager.sh" status --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" || true
    else
        log_info "Status: Dry run completed"
    fi
    
    log_info "=========================="
}

main() {
    log_info "Starting game server deployment..."
    
    parse_arguments "$@"
    validate_deployment_environment
    
    # Create backup before deployment (skip in dry run)
    if [[ "$DRY_RUN" == "false" ]]; then
        backup_current_deployment
    fi
    
    # Deploy server
    deploy_server
    
    # Run health checks
    run_health_checks
    
    # Show summary
    show_deployment_summary
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run completed successfully"
    else
        log_info "Deployment completed successfully"
    fi
}

# Run main function with all arguments
main "$@"