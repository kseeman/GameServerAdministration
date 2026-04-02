#!/bin/bash
set -euo pipefail

# Scheduled Configuration Swapper for Instance + Preset Architecture
# Automatically switches server presets based on schedule (e.g., tournament PvE/PvP rotation)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

# Configuration
LOG_FILE="/var/log/gameserver-config-swap.log"
CONFIG_FILE="$PROJECT_ROOT/config/schedule-config.json"

show_usage() {
    cat << EOF
Scheduled Configuration Swapper for Game Servers

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --game <game>           Game to manage (palworld, valheim, etc.)
  --instance <instance>   Server instance name (main, backup, tournament, etc.)
  --env <environment>     Environment (staging, production)
  --schedule-file <file>  Custom schedule configuration file
  --dry-run              Show what would be changed without executing
  --force                Skip safety checks and swap anyway
  --quiet                Minimal output (for cron jobs)
  --check-only           Only check what preset should be active now
  -h, --help             Show this help

EXAMPLES:
  $0 --game palworld --instance tournament --env production
  $0 --game palworld --instance main --env production --check-only
  $0 --dry-run

CRON EXAMPLES:
  # Check and swap every hour
  0 * * * * /path/to/scheduled-config-swap.sh --game palworld --instance tournament --env production --quiet

  # Check twice per day (morning/evening)
  0 6,18 * * * /path/to/scheduled-config-swap.sh --game palworld --instance tournament --env production --quiet

SCHEDULE FORMAT (JSON):
{
  "schedules": {
    "palworld-tournament": {
      "monday": "tournament-pve",
      "tuesday": "tournament-pve", 
      "wednesday": "tournament",
      "thursday": "tournament",
      "friday": "tournament-pve",
      "saturday": "tournament", 
      "sunday": "tournament",
      "default": "tournament-pve"
    }
  }
}

EOF
}

# Parse arguments
GAME=""
INSTANCE=""
ENVIRONMENT=""
SCHEDULE_FILE="$CONFIG_FILE"
DRY_RUN=false
FORCE=false
QUIET=false
CHECK_ONLY=false

parse_arguments() {
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
            --schedule-file)
                SCHEDULE_FILE="$2"
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
            --check-only)
                CHECK_ONLY=true
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
    if [[ -z "$GAME" || -z "$INSTANCE" || -z "$ENVIRONMENT" ]]; then
        log_error "Missing required arguments: --game, --instance, and --env are required"
        show_usage
        exit 1
    fi
}

# Enhanced logging for scheduled jobs
log_swap() {
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
        echo "[$timestamp] [$level] [$GAME-$INSTANCE-$ENVIRONMENT] $message" >> "$LOG_FILE"
    fi
}

# Create default schedule configuration
create_default_schedule() {
    local schedule_dir=$(dirname "$SCHEDULE_FILE")
    mkdir -p "$schedule_dir"
    
    cat > "$SCHEDULE_FILE" << EOF
{
  "metadata": {
    "description": "Scheduled configuration swapping for game servers",
    "version": "1.0",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "schedules": {
    "palworld-tournament": {
      "monday": "tournament-pve",
      "tuesday": "tournament-pve",
      "wednesday": "tournament",
      "thursday": "tournament",
      "friday": "tournament-pve",
      "saturday": "tournament",
      "sunday": "tournament",
      "default": "tournament-pve",
      "description": "Tournament server: Mon-Tue,Fri = PvE, Wed-Thu,Sat-Sun = PvP"
    },
    "palworld-main": {
      "monday": "default",
      "tuesday": "default",
      "wednesday": "default",
      "thursday": "default",
      "friday": "casual",
      "saturday": "casual",
      "sunday": "casual",
      "default": "default",
      "description": "Main server: Weekdays = default, Weekends = casual"
    }
  },
  "backup_before_swap": true,
  "health_check_after_swap": true,
  "swap_window": {
    "start_hour": 6,
    "end_hour": 22,
    "description": "Only perform swaps between 6 AM and 10 PM"
  }
}
EOF

    log_swap "INFO" "Created default schedule configuration: $SCHEDULE_FILE"
}

# Get current day of week in lowercase
get_current_day() {
    date '+%A' | tr '[:upper:]' '[:lower:]'
}

# Get current hour (24-hour format)
get_current_hour() {
    date '+%H'
}

# Get target preset for current day/time
get_target_preset() {
    local schedule_key="${GAME}-${INSTANCE}"
    local current_day=$(get_current_day)
    
    if [[ ! -f "$SCHEDULE_FILE" ]]; then
        log_swap "WARNING" "Schedule file not found, creating default: $SCHEDULE_FILE"
        create_default_schedule
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        log_swap "ERROR" "jq is required for schedule processing"
        exit 1
    fi
    
    # Get preset for current day
    local target_preset=$(jq -r ".schedules.\"$schedule_key\".\"$current_day\" // .schedules.\"$schedule_key\".default // \"unknown\"" "$SCHEDULE_FILE")
    
    if [[ "$target_preset" == "unknown" || "$target_preset" == "null" ]]; then
        log_swap "ERROR" "No schedule found for $schedule_key on $current_day"
        return 1
    fi
    
    echo "$target_preset"
}

# Get current active preset from state file
get_current_preset() {
    local state_file="${PROJECT_ROOT}/.state/${GAME}-${ENVIRONMENT}-${INSTANCE}.preset"

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# Check if we're in the allowed swap window
is_in_swap_window() {
    local current_hour=$(get_current_hour)
    local start_hour=6
    local end_hour=22
    
    if [[ -f "$SCHEDULE_FILE" ]] && command -v jq >/dev/null 2>&1; then
        start_hour=$(jq -r '.swap_window.start_hour // 6' "$SCHEDULE_FILE")
        end_hour=$(jq -r '.swap_window.end_hour // 22' "$SCHEDULE_FILE")
    fi
    
    if [[ $current_hour -ge $start_hour && $current_hour -le $end_hour ]]; then
        return 0
    else
        return 1
    fi
}

# Check if backup should be created before swap
should_backup_before_swap() {
    local backup_setting=true
    
    if [[ -f "$SCHEDULE_FILE" ]] && command -v jq >/dev/null 2>&1; then
        backup_setting=$(jq -r '.backup_before_swap // true' "$SCHEDULE_FILE")
    fi
    
    [[ "$backup_setting" == "true" ]]
}

# Perform configuration swap
perform_config_swap() {
    local current_preset="$1"
    local target_preset="$2"
    local server_id="${GAME}-${INSTANCE}-${ENVIRONMENT}"
    
    log_swap "INFO" "Starting config swap: $current_preset -> $target_preset"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_swap "INFO" "[DRY-RUN] Would swap $server_id from $current_preset to $target_preset"
        return 0
    fi
    
    # Create backup if configured
    if should_backup_before_swap && [[ "$FORCE" != true ]]; then
        log_swap "INFO" "Creating backup before config swap..."
        
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_name="pre-swap_${current_preset}_${timestamp}"
        
        if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" backup --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --quiet; then
            log_swap "WARNING" "Backup failed, but continuing with swap"
        else
            log_swap "SUCCESS" "Pre-swap backup created"
        fi
    fi
    
    # Perform the restart with new preset
    log_swap "INFO" "Restarting server with preset: $target_preset"
    
    if "$PROJECT_ROOT/scripts/core/server-manager.sh" config-swap --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --preset "$target_preset" --force; then
        log_swap "SUCCESS" "Config swap completed: $server_id now running $target_preset"
        
        # Health check if configured
        local health_check=true
        if [[ -f "$SCHEDULE_FILE" ]] && command -v jq >/dev/null 2>&1; then
            health_check=$(jq -r '.health_check_after_swap // true' "$SCHEDULE_FILE")
        fi
        
        if [[ "$health_check" == "true" ]]; then
            sleep 30  # Give server time to start
            if "$PROJECT_ROOT/scripts/core/server-manager.sh" health --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --quiet; then
                log_swap "SUCCESS" "Post-swap health check passed"
            else
                log_swap "WARNING" "Post-swap health check failed - server may need attention"
            fi
        fi
        
        return 0
    else
        log_swap "ERROR" "Config swap failed for $server_id"
        return 1
    fi
}

# Main scheduling logic
run_scheduled_swap() {
    local server_id="${GAME}-${INSTANCE}-${ENVIRONMENT}"
    log_swap "INFO" "Checking scheduled config for $server_id"
    
    # Get target preset for current time
    local target_preset
    if ! target_preset=$(get_target_preset); then
        return 1
    fi
    
    log_swap "INFO" "Target preset for $(get_current_day): $target_preset"
    
    if [[ "$CHECK_ONLY" == true ]]; then
        echo "Target preset: $target_preset"
        return 0
    fi
    
    # Get current preset
    local current_preset=$(get_current_preset)
    log_swap "INFO" "Current preset: $current_preset"
    
    # Check if swap is needed
    if [[ "$current_preset" == "$target_preset" ]]; then
        log_swap "INFO" "No config change needed - already running $target_preset"
        return 0
    fi
    
    # Check if we're in the allowed swap window
    if ! is_in_swap_window && [[ "$FORCE" != true ]]; then
        local current_hour=$(get_current_hour)
        log_swap "INFO" "Outside swap window (current hour: $current_hour), skipping swap"
        return 0
    fi
    
    # Perform the swap
    perform_config_swap "$current_preset" "$target_preset"
}

# Show current schedule
show_schedule() {
    local schedule_key="${GAME}-${INSTANCE}"
    
    if [[ ! -f "$SCHEDULE_FILE" ]]; then
        log_swap "INFO" "No schedule file found, would use defaults"
        return 0
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        log_swap "ERROR" "jq is required to display schedule"
        return 1
    fi
    
    local schedule_exists=$(jq -r ".schedules.\"$schedule_key\" // \"null\"" "$SCHEDULE_FILE")
    
    if [[ "$schedule_exists" == "null" ]]; then
        log_swap "INFO" "No schedule configured for $schedule_key"
        return 0
    fi
    
    log_swap "INFO" "Schedule for $schedule_key:"
    
    local description=$(jq -r ".schedules.\"$schedule_key\".description // \"No description\"" "$SCHEDULE_FILE")
    [[ "$QUIET" != true ]] && echo "Description: $description"
    
    for day in monday tuesday wednesday thursday friday saturday sunday; do
        local preset=$(jq -r ".schedules.\"$schedule_key\".\"$day\" // \"default\"" "$SCHEDULE_FILE")
        [[ "$QUIET" != true ]] && echo "  $day: $preset"
    done
    
    local default_preset=$(jq -r ".schedules.\"$schedule_key\".default // \"unknown\"" "$SCHEDULE_FILE")
    [[ "$QUIET" != true ]] && echo "  default: $default_preset"
}

# Main execution
main() {
    parse_arguments "$@"
    
    # Validate environment
    if ! validate_environment "$ENVIRONMENT"; then
        exit 1
    fi
    
    # Show schedule if in verbose mode
    if [[ "$QUIET" != true && "$CHECK_ONLY" != true ]]; then
        show_schedule
    fi
    
    # Run the scheduled swap
    run_scheduled_swap
}

# Run main function with all arguments
main "$@"