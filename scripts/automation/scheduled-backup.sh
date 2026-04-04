#!/bin/bash
set -euo pipefail

# Automated Backup Scheduler for Instance + Preset Architecture
# Discovers running instances and creates scheduled backups with preset tracking

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"
source "$PROJECT_ROOT/scripts/shared/game-plugins.sh"

# Configuration
BACKUP_TYPE="scheduled"
LOG_FILE="/var/log/gameserver-backup.log"
MAX_CONCURRENT_BACKUPS=2
BACKUP_TIMEOUT=300  # 5 minutes per backup

show_usage() {
    cat << EOF
Scheduled Backup System for Game Servers

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --env <environment>    Target environment (staging, production, or all)
  --game <game>         Target game (palworld, valheim, etc., or all)
  --dry-run            Show what would be backed up without executing
  --force              Skip health checks and backup anyway
  --quiet              Minimal output (for cron jobs)
  --verbose            Detailed output
  -h, --help           Show this help

EXAMPLES:
  $0 --env production --game palworld    # Backup all Palworld production instances
  $0 --env all --game all                # Backup everything
  $0 --dry-run                          # See what would be backed up
  $0 --quiet                            # Silent operation for cron

CRON EXAMPLES:
  # Every 4 hours - production backups
  0 */4 * * * /path/to/scheduled-backup.sh --env production --quiet

  # Every 6 hours - staging backups  
  0 */6 * * * /path/to/scheduled-backup.sh --env staging --quiet

  # Daily full backup
  0 2 * * * /path/to/scheduled-backup.sh --env all --game all --quiet

EOF
}

# Parse arguments
ENVIRONMENT="all"
GAME="all"
DRY_RUN=false
FORCE=false
QUIET=false
VERBOSE=false

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
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --verbose)
                VERBOSE=true
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
}

# Enhanced logging for scheduled jobs
log_backup() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")
            [[ "$QUIET" != true ]] && log_info "$message"
            ;;
        "SUCCESS")
            [[ "$QUIET" != true ]] && log_success "$message"
            ;;
        "WARNING")
            log_warning "$message"
            ;;
        "ERROR")
            log_error "$message"
            ;;
    esac
    
    # Always log to file if possible
    if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Discover running instances
discover_instances() {
    local running_instances=()

    log_backup "INFO" "Discovering running game server instances..." >&2
    
    # Get all running containers that match our naming pattern: {game}-{env}-{instance}
    local containers=$(docker ps --format "{{.Names}}" || true)

    while IFS= read -r container_name; do
        [[ -z "$container_name" ]] && continue

        # Parse container name: {game}-{env}-{instance}
        # env must be "staging" or "production"
        if [[ "$container_name" =~ ^([a-zA-Z0-9]+)-(staging|production)-([a-zA-Z0-9-]+)$ ]]; then
            local game="${BASH_REMATCH[1]}"
            local env="${BASH_REMATCH[2]}"
            local instance="${BASH_REMATCH[3]}"
            
            # Filter by environment if specified
            if [[ "$ENVIRONMENT" != "all" && "$env" != "$ENVIRONMENT" ]]; then
                continue
            fi
            
            # Filter by game if specified
            if [[ "$GAME" != "all" && "$game" != "$GAME" ]]; then
                continue
            fi
            
            running_instances+=("$game:$env:$instance")
            
            if [[ "$VERBOSE" == true ]]; then
                log_backup "INFO" "Found instance: $game-$env-$instance" >&2
            fi
        fi
    done <<< "$containers"
    
    echo "${running_instances[@]}"
}

# Get active preset for an instance
get_active_preset() {
    local game="$1"
    local env="$2"
    local instance="$3"

    local state_file="${PROJECT_ROOT}/.state/${game}-${env}-${instance}.preset"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# Check if instance should be backed up
should_backup_instance() {
    local game="$1"
    local env="$2"
    local instance="$3"
    
    # Skip if forced
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    
    # Health check the instance
    local container_name="${game}-${env}-${instance}"
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        log_backup "WARNING" "Container $container_name not running, skipping backup"
        return 1
    fi
    
    # Check container health if available
    local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
    
    if [[ "$health_status" == "unhealthy" ]]; then
        log_backup "WARNING" "Container $container_name is unhealthy, skipping backup"
        return 1
    fi
    
    # Check if volume exists
    local volume_name="${game}-vol-${env}-${instance}"
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log_backup "WARNING" "Volume $volume_name not found, skipping backup"
        return 1
    fi
    
    return 0
}

# Backup single instance
backup_instance() {
    local game="$1"
    local env="$2"
    local instance="$3"
    
    local instance_id="${game}-${env}-${instance}"
    log_backup "INFO" "Starting backup for instance: $instance_id"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_backup "INFO" "[DRY-RUN] Would backup $instance_id"
        return 0
    fi
    
    # Get active preset
    local active_preset=$(get_active_preset "$game" "$env" "$instance")
    
    # Generate backup name
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="${BACKUP_TYPE}_${active_preset}_${instance}_${env}_${timestamp}"
    
    # Call game-specific backup function
    if ! load_game_plugin "$game" "$env"; then
        log_backup "ERROR" "Failed to load game plugin for $game"
        return 1
    fi
    
    # Use timeout to prevent hanging
    local backup_result
    if timeout "$BACKUP_TIMEOUT" bash -c "call_plugin_function \"$game\" \"backup_data\" \"$instance\" \"$env\" \"$backup_name\" \"$active_preset\""; then
        log_backup "SUCCESS" "Backup completed for $instance_id: $backup_name"
        
        # Clean old backups based on environment retention policy
        cleanup_old_backups "$game" "$env" "$instance"
        
        return 0
    else
        log_backup "ERROR" "Backup failed or timed out for $instance_id"
        return 1
    fi
}

# Clean old backups based on retention policy
cleanup_old_backups() {
    local game="$1"
    local env="$2"
    local instance="$3"
    
    local backup_dir="$PROJECT_ROOT/backups/${env}/${instance}"
    [[ ! -d "$backup_dir" ]] && return 0
    
    # Get retention policy from game environment config
    local config=$(get_game_env_config "$game" "$env")
    local retention=10  # Default

    if [[ -f "$config" ]] && command -v jq >/dev/null 2>&1; then
        retention=$(jq -r '.backup_config.backup_retention // 10' "$config")
    fi
    
    # Keep only recent backups, remove oldest
    local backup_count=$(find "$backup_dir" -name "*.tar.gz" -type f | wc -l)
    
    if [[ $backup_count -gt $retention ]]; then
        local to_delete=$((backup_count - retention))
        log_backup "INFO" "Cleaning up $to_delete old backups for $game-$env-$instance"
        
        # Remove oldest files
        find "$backup_dir" -name "*.tar.gz" -type f -printf '%T@ %p\n' | \
            sort -n | \
            head -n "$to_delete" | \
            cut -d' ' -f2- | \
            while read -r file; do
                [[ "$VERBOSE" == true ]] && log_backup "INFO" "Removing old backup: $(basename "$file")"
                rm -f "$file"
                
                # Also remove associated metadata file
                local meta_file="${file%.tar.gz}.meta.json"
                [[ -f "$meta_file" ]] && rm -f "$meta_file"
            done
    fi
}

# Main backup orchestration
run_scheduled_backup() {
    log_backup "INFO" "Starting scheduled backup run (env: $ENVIRONMENT, game: $GAME)"
    
    local instances=($(discover_instances))
    local total_instances=${#instances[@]}
    
    if [[ $total_instances -eq 0 ]]; then
        log_backup "WARNING" "No running instances found matching criteria"
        return 0
    fi
    
    log_backup "INFO" "Found $total_instances instances to backup"
    
    local success_count=0
    local failure_count=0
    local skip_count=0
    
    # Process instances with concurrency control
    local active_jobs=0
    
    for instance_spec in "${instances[@]}"; do
        IFS=':' read -r game env instance <<< "$instance_spec"
        
        # Check if we should backup this instance
        if ! should_backup_instance "$game" "$env" "$instance"; then
            ((skip_count++))
            continue
        fi
        
        # Wait for available slot if at max concurrency
        while [[ $active_jobs -ge $MAX_CONCURRENT_BACKUPS ]]; do
            sleep 5
            # Count active background jobs
            active_jobs=$(jobs -r | wc -l)
        done
        
        # Start backup in background
        (
            if backup_instance "$game" "$env" "$instance"; then
                exit 0
            else
                exit 1
            fi
        ) &
        
        ((active_jobs++))
    done
    
    # Wait for all background jobs to complete
    for job in $(jobs -p); do
        if wait "$job"; then
            ((success_count++))
        else
            ((failure_count++))
        fi
    done
    
    # Final summary
    log_backup "INFO" "Backup run completed: $success_count successful, $failure_count failed, $skip_count skipped"
    
    if [[ $failure_count -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Main execution
main() {
    parse_arguments "$@"
    
    # Validate environment
    if [[ "$ENVIRONMENT" != "all" ]]; then
        if ! validate_environment "$ENVIRONMENT"; then
            exit 1
        fi
    fi
    
    # Run the backup
    run_scheduled_backup
}

# Run main function with all arguments
main "$@"