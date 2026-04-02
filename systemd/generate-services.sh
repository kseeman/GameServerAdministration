#!/bin/bash
set -euo pipefail

# Generate Systemd Service Files Script
# Creates environment-specific systemd service files from templates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

# Default values
ENVIRONMENT=""
FORCE=false
DRY_RUN=false

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate systemd service files for game servers

OPTIONS:
    --env ENV           Environment: staging or production (required)
    --force            Overwrite existing service files
    --dry-run          Show what files would be generated without creating them
    -h, --help         Show this help message

EXAMPLES:
    # Generate staging services
    $0 --env staging

    # Generate production services (overwrite existing)
    $0 --env production --force

    # Dry run to see what would be generated
    $0 --env staging --dry-run

EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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
    if [[ -z "$ENVIRONMENT" ]]; then
        log_error "Missing required argument: --env"
        show_usage
        exit 1
    fi
}

validate_environment() {
    log_info "Validating environment: $ENVIRONMENT"
    
    # Check if any game has a config for this environment
    local found=false
    for config in "$PROJECT_ROOT"/games/*/environments/${ENVIRONMENT}.json; do
        [[ -f "$config" ]] && found=true && break
    done
    if [[ "$found" != true ]]; then
        log_error "No game configs found for environment: $ENVIRONMENT"
        exit 1
    fi

    log_info "Environment validation passed"
}

generate_service_files() {
    local output_dir="$PROJECT_ROOT/systemd/$ENVIRONMENT"
    local template_file="$PROJECT_ROOT/systemd/templates/game-server@.service.template"

    log_info "Generating systemd service files for environment: $ENVIRONMENT"

    # Create output directory
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "$output_dir"
    else
        log_info "[DRY RUN] Would create directory: $output_dir"
    fi

    # Discover supported games from games/ directory
    local supported_games=""
    for game_dir in "$PROJECT_ROOT"/games/*/; do
        local game=$(basename "$game_dir")
        local config="$game_dir/environments/${ENVIRONMENT}.json"
        if [[ -f "$config" ]]; then
            supported_games+="$game"$'\n'
        fi
    done

    if [[ -z "$supported_games" ]]; then
        log_error "No supported games found for environment: $ENVIRONMENT"
        exit 1
    fi

    # Generate service files for each game
    while IFS= read -r game; do
        if [[ -z "$game" ]]; then
            continue
        fi

        log_info "Processing game: $game"

        # Read game environment config
        local config="$PROJECT_ROOT/games/$game/environments/${ENVIRONMENT}.json"

        # Read supported instances for this game
        local supported_contexts
        supported_contexts=$(jq -r '.instances | keys[]' "$config" 2>/dev/null || echo "")
        
        if [[ -z "$supported_contexts" ]]; then
            log_warn "No supported contexts found for game: $game"
            continue
        fi
        
        # Generate service file for each context
        while IFS= read -r context; do
            if [[ -z "$context" ]]; then
                continue
            fi
            
            local service_name="${game}-${ENVIRONMENT}-${context}"
            local service_file="$output_dir/game-server@${service_name}.service"
            
            log_info "Generating service file: $service_name"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would generate: $service_file"
                continue
            fi
            
            # Check if file exists and force not specified
            if [[ -f "$service_file" && "$FORCE" == "false" ]]; then
                log_warn "Service file already exists (use --force to overwrite): $service_file"
                continue
            fi
            
            # Create service file from template with environment-specific modifications
            local temp_file
            temp_file=$(mktemp)
            
            # Copy template and make environment-specific substitutions
            cp "$template_file" "$temp_file"
            
            # Replace template variables
            sed -i "s|%i|${service_name}|g" "$temp_file"
            sed -i "s|Game Server - %i|Game Server - ${game} (${ENVIRONMENT}/${context})|g" "$temp_file"
            sed -i "s|game-server-%i|game-server-${service_name}|g" "$temp_file"
            
            # Environment-specific adjustments
            case "$ENVIRONMENT" in
                staging)
                    # Staging: More aggressive restart policy, longer timeout
                    sed -i "s|TimeoutStartSec=600|TimeoutStartSec=900|g" "$temp_file"
                    sed -i "s|RestartSec=30|RestartSec=10|g" "$temp_file"
                    ;;
                production)
                    # Production: More conservative restart policy
                    sed -i "s|Restart=on-failure|Restart=always|g" "$temp_file"
                    sed -i "s|RestartSec=30|RestartSec=60|g" "$temp_file"
                    ;;
            esac
            
            # Move to final location
            mv "$temp_file" "$service_file"
            
            # Set appropriate permissions
            chmod 644 "$service_file"
            
            log_info "✓ Generated: $service_file"
            
        done <<< "$supported_contexts"
        
    done <<< "$supported_games"
}

generate_install_script() {
    local output_dir="$PROJECT_ROOT/systemd/$ENVIRONMENT"
    local install_script="$output_dir/install-services.sh"
    
    log_info "Generating installation script..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate: $install_script"
        return 0
    fi
    
    cat > "$install_script" << EOF
#!/bin/bash
set -euo pipefail

# Auto-generated systemd service installation script for $ENVIRONMENT environment
# Generated on: $(date)

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

echo "Installing systemd service files for $ENVIRONMENT environment..."

# Copy service files to systemd directory
for service_file in "\$SCRIPT_DIR"/*.service; do
    if [[ -f "\$service_file" ]]; then
        service_name=\$(basename "\$service_file")
        echo "Installing: \$service_name"
        sudo cp "\$service_file" "/etc/systemd/system/"
    fi
done

# Reload systemd
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Service files installed successfully!"
echo ""
echo "To enable and start a service:"
echo "  sudo systemctl enable game-server@GAME-$ENVIRONMENT-CONTEXT"
echo "  sudo systemctl start game-server@GAME-$ENVIRONMENT-CONTEXT"
echo ""
echo "To check service status:"
echo "  sudo systemctl status game-server@GAME-$ENVIRONMENT-CONTEXT"
EOF
    
    chmod +x "$install_script"
    log_info "✓ Generated installation script: $install_script"
}

generate_uninstall_script() {
    local output_dir="$PROJECT_ROOT/systemd/$ENVIRONMENT"
    local uninstall_script="$output_dir/uninstall-services.sh"
    
    log_info "Generating uninstallation script..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would generate: $uninstall_script"
        return 0
    fi
    
    cat > "$uninstall_script" << EOF
#!/bin/bash
set -euo pipefail

# Auto-generated systemd service uninstallation script for $ENVIRONMENT environment
# Generated on: $(date)

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

echo "Uninstalling systemd service files for $ENVIRONMENT environment..."

# Stop and disable services first
for service_file in "\$SCRIPT_DIR"/*.service; do
    if [[ -f "\$service_file" ]]; then
        service_name=\$(basename "\$service_file")
        system_service="/etc/systemd/system/\$service_name"
        
        if [[ -f "\$system_service" ]]; then
            echo "Stopping and disabling: \$service_name"
            sudo systemctl stop "\$service_name" 2>/dev/null || true
            sudo systemctl disable "\$service_name" 2>/dev/null || true
            
            echo "Removing: \$service_name"
            sudo rm -f "\$system_service"
        fi
    fi
done

# Reload systemd
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload
sudo systemctl reset-failed

echo "Service files uninstalled successfully!"
EOF
    
    chmod +x "$uninstall_script"
    log_info "✓ Generated uninstallation script: $uninstall_script"
}

show_summary() {
    local output_dir="$PROJECT_ROOT/systemd/$ENVIRONMENT"
    
    log_info "=== Service Generation Summary ==="
    log_info "Environment: $ENVIRONMENT"
    log_info "Output Directory: $output_dir"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        local service_count
        service_count=$(find "$output_dir" -name "*.service" 2>/dev/null | wc -l || echo "0")
        log_info "Generated Services: $service_count"
        
        log_info ""
        log_info "Next steps:"
        log_info "1. Review generated service files in: $output_dir"
        log_info "2. Install services: $output_dir/install-services.sh"
        log_info "3. Enable/start specific services as needed"
    else
        log_info "Status: Dry run completed"
    fi
    
    log_info "================================"
}

main() {
    log_info "Starting systemd service generation..."
    
    parse_arguments "$@"
    validate_environment
    
    # Generate service files
    generate_service_files
    
    # Generate helper scripts
    generate_install_script
    generate_uninstall_script
    
    # Show summary
    show_summary
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Dry run completed successfully"
    else
        log_info "Service generation completed successfully"
    fi
}

# Run main function with all arguments
main "$@"