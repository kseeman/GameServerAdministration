#!/bin/bash
set -euo pipefail

# Setup Helper for Scheduled Configuration Swapping
# Sets up automatic preset switching for tournament servers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

show_usage() {
    cat << EOF
Setup Helper for Scheduled Configuration Swapping

USAGE:
  $0 [OPTIONS]

OPTIONS:
  --install        Install cron job for config swapping
  --remove         Remove config swap cron jobs
  --list           Show current config swap schedule
  --test           Test the config swap system
  --dry-run        Show what would be configured
  --game <game>    Target game (default: palworld)
  --instance <name> Target instance (default: tournament)
  --env <env>      Environment (default: production)
  -h, --help       Show this help

EXAMPLES:
  $0 --install                           # Install default tournament schedule
  $0 --install --instance main          # Install schedule for main server
  $0 --test                             # Test what preset should be active now
  $0 --list                             # Show current schedules

EOF
}

# Parse arguments
OPERATION=""
GAME="palworld"
INSTANCE="tournament"
ENVIRONMENT="production"
DRY_RUN=false

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install)
                OPERATION="install"
                shift
                ;;
            --remove)
                OPERATION="remove"
                shift
                ;;
            --list)
                OPERATION="list"
                shift
                ;;
            --test)
                OPERATION="test"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
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
    
    if [[ -z "$OPERATION" ]]; then
        log_error "Operation required (--install, --remove, --list, or --test)"
        show_usage
        exit 1
    fi
}

# Create tournament schedule configuration
create_tournament_schedule() {
    local config_file="$PROJECT_ROOT/config/schedule-config.json"
    local config_dir=$(dirname "$config_file")
    
    mkdir -p "$config_dir"
    
    log_info "Creating tournament schedule configuration..."
    
    cat > "$config_file" << EOF
{
  "metadata": {
    "description": "Scheduled configuration swapping for game servers",
    "version": "1.0",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "updated_by": "setup-config-swap.sh"
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

    log_success "Tournament schedule configuration created: $config_file"
}

# Install cron job for config swapping
install_config_swap() {
    log_info "Installing scheduled configuration swap for $GAME-$INSTANCE-$ENVIRONMENT..."
    
    # Ensure schedule config exists
    local config_file="$PROJECT_ROOT/config/schedule-config.json"
    if [[ ! -f "$config_file" ]]; then
        create_tournament_schedule
    fi
    
    # Generate cron job
    local script_path="$PROJECT_ROOT/scripts/automation/scheduled-config-swap.sh"
    local log_file="/var/log/gameserver-config-swap.log"
    
    # Check every hour (you can adjust this)
    local cron_schedule="0 * * * *"
    local cron_entry="$cron_schedule $script_path --game $GAME --instance $INSTANCE --env $ENVIRONMENT --quiet >> $log_file 2>&1"
    local cron_comment="# Automated config swap for $GAME-$INSTANCE-$ENVIRONMENT - GameServerAdministration"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would install cron job:"
        echo "$cron_comment"
        echo "$cron_entry"
        return 0
    fi
    
    # Get current crontab and add new entry
    local temp_cron=$(mktemp)
    
    # Preserve existing cron jobs, but remove any existing config swap for same server
    crontab -l 2>/dev/null | grep -v "config-swap.*$GAME.*$INSTANCE.*$ENVIRONMENT" | grep -v "GameServerAdministration.*config" > "$temp_cron" || true
    
    # Add new cron job
    echo "" >> "$temp_cron"
    echo "$cron_comment" >> "$temp_cron"
    echo "$cron_entry" >> "$temp_cron"
    
    # Install new crontab
    if crontab "$temp_cron"; then
        log_success "Config swap cron job installed successfully"
        
        # Create log file
        sudo touch "$log_file" 2>/dev/null || touch "$log_file" 2>/dev/null || true
        
        log_info "Schedule: Check every hour for config changes"
        log_info "Log file: $log_file"
    else
        log_error "Failed to install config swap cron job"
        rm -f "$temp_cron"
        return 1
    fi
    
    rm -f "$temp_cron"
}

# Remove config swap cron jobs
remove_config_swap() {
    log_info "Removing config swap cron jobs..."
    
    # Get current crontab without config swap entries
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "scheduled-config-swap.sh\|GameServerAdministration.*config" > "$temp_cron" || true
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would remove config swap cron jobs"
        return 0
    fi
    
    # Install cleaned crontab
    if crontab "$temp_cron"; then
        log_success "Config swap cron jobs removed"
    else
        log_error "Failed to remove cron jobs"
        rm -f "$temp_cron"
        return 1
    fi
    
    rm -f "$temp_cron"
}

# List current config swap schedules
list_config_swaps() {
    log_info "Current config swap schedules:"
    
    # Show cron jobs
    local cron_content=$(crontab -l 2>/dev/null || echo "")
    
    if echo "$cron_content" | grep -q "scheduled-config-swap.sh"; then
        echo "--- Config Swap Cron Jobs ---"
        echo "$cron_content" | grep -A 1 -B 1 "scheduled-config-swap.sh\|GameServerAdministration.*config" | grep -v "^--$"
        echo ""
    else
        log_info "No config swap cron jobs found"
    fi
    
    # Show schedule configuration
    local config_file="$PROJECT_ROOT/config/schedule-config.json"
    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        echo "--- Tournament Schedule ---"
        jq -r '.schedules."palworld-tournament" | to_entries[] | "\(.key): \(.value)"' "$config_file" | head -8
        echo ""
        
        local description=$(jq -r '.schedules."palworld-tournament".description' "$config_file")
        echo "Description: $description"
        echo ""
        
        # Show current day target
        local current_day=$(date '+%A' | tr '[:upper:]' '[:lower:]')
        local current_preset=$(jq -r ".schedules.\"palworld-tournament\".\"$current_day\" // .schedules.\"palworld-tournament\".default" "$config_file")
        echo "Today ($current_day): $current_preset"
        
    else
        log_warning "No schedule configuration found: $config_file"
    fi
}

# Test the config swap system
test_config_swap() {
    local script_path="$PROJECT_ROOT/scripts/automation/scheduled-config-swap.sh"
    
    log_info "Testing config swap system for $GAME-$INSTANCE-$ENVIRONMENT..."
    
    # Check what preset should be active now
    log_info "Checking current target preset..."
    "$script_path" --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --check-only
    
    # Show dry run of what would happen
    log_info "Showing what would happen in a swap:"
    "$script_path" --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --dry-run
    
    # Validate script works
    if "$script_path" --game "$GAME" --instance "$INSTANCE" --env "$ENVIRONMENT" --check-only >/dev/null 2>&1; then
        log_success "Config swap system is working correctly"
    else
        log_error "Config swap system has issues"
        return 1
    fi
}

# Show tournament schedule summary  
show_tournament_summary() {
    log_info "=== Tournament Schedule Summary ==="
    log_info "Your tournament schedule:"
    log_info "  Monday-Tuesday: PvE Mode (tournament-pve preset)"
    log_info "  Wednesday-Thursday: PvP Mode (tournament preset)"
    log_info "  Friday: PvE Mode (tournament-pve preset)"
    log_info "  Saturday-Sunday: PvP Mode (tournament preset)"
    log_info ""
    log_info "Features:"
    log_info "  - Automatic backup before each swap"
    log_info "  - Health check after each swap"
    log_info "  - Only swaps between 6 AM and 10 PM"
    log_info "  - Checks every hour for needed changes"
    log_info ""
    log_info "Commands:"
    log_info "  - Manual check: ./scripts/automation/scheduled-config-swap.sh --game $GAME --instance $INSTANCE --env $ENVIRONMENT --check-only"
    log_info "  - Manual swap: ./scripts/automation/scheduled-config-swap.sh --game $GAME --instance $INSTANCE --env $ENVIRONMENT"
    log_info "  - View logs: tail -f /var/log/gameserver-config-swap.log"
}

# Main execution
main() {
    parse_arguments "$@"
    
    case "$OPERATION" in
        "install")
            show_tournament_summary
            install_config_swap
            ;;
        "remove")
            remove_config_swap
            ;;
        "list")
            list_config_swaps
            ;;
        "test")
            test_config_swap
            ;;
    esac
}

# Run main function with all arguments
main "$@"