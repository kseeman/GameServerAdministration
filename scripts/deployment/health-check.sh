#!/bin/bash
set -euo pipefail

# Game Server Health Check Script
# Validates that deployed servers are healthy and responding

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source dependencies
source "$PROJECT_ROOT/scripts/shared/server-utils.sh"

# Default values
ENVIRONMENT=""
GAME=""
CONTEXT=""
VERBOSE=false
TIMEOUT=60
MAX_RETRIES=3

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run health checks on deployed game servers

OPTIONS:
    --env ENV           Environment: staging or production (required)
    --game GAME         Game type (required)
    --context CONTEXT   Server context (required)
    --timeout SECONDS   Health check timeout in seconds (default: 60)
    --retries NUM       Maximum number of retry attempts (default: 3)
    --verbose          Show detailed health check output
    -h, --help         Show this help message

EXAMPLES:
    # Basic health check
    $0 --env staging --game palworld --context tournament

    # Health check with custom timeout and retries
    $0 --env production --game palworld --context main --timeout 120 --retries 5

    # Verbose health check output
    $0 --env staging --game palworld --context test --verbose

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
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --retries)
                MAX_RETRIES="$2"
                shift 2
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

    # Validate required arguments
    if [[ -z "$ENVIRONMENT" || -z "$GAME" || -z "$CONTEXT" ]]; then
        log_error "Missing required arguments"
        show_usage
        exit 1
    fi
}

check_container_running() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    local container_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Checking if container is running: $container_name"
    fi
    
    if docker ps --format "table {{.Names}}" | grep -q "^${container_name}$"; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "✓ Container is running"
        fi
        return 0
    else
        log_error "✗ Container is not running: $container_name"
        return 1
    fi
}

check_container_health() {
    local container_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Checking container health status..."
    fi
    
    # Get container health status if health check is configured
    local health_status
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
    
    if [[ "$health_status" == "healthy" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "✓ Container health status: healthy"
        fi
        return 0
    elif [[ "$health_status" == "starting" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "⏳ Container health status: starting (still initializing)"
        fi
        return 2  # Special return code for "still starting"
    elif [[ "$health_status" == "unhealthy" ]]; then
        log_error "✗ Container health status: unhealthy"
        return 1
    else
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "ℹ Container health check not configured"
        fi
        return 0  # No health check configured is OK
    fi
}

check_container_logs() {
    local container_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Checking container logs for errors..."
    fi
    
    # Get recent logs and check for common error patterns
    local recent_logs
    recent_logs=$(docker logs --tail 50 "$container_name" 2>&1 || echo "")
    
    # Game-specific error pattern checking
    case "$GAME" in
        palworld)
            if echo "$recent_logs" | grep -qi "error\|failed\|crash\|exception"; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log_error "✗ Error patterns found in logs"
                    echo "$recent_logs" | grep -i "error\|failed\|crash\|exception" | tail -5
                fi
                return 1
            fi
            
            # Check for successful startup messages
            if echo "$recent_logs" | grep -qi "world started\|server.*ready\|listening.*port"; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log_info "✓ Server startup messages found in logs"
                fi
                return 0
            fi
            ;;
        *)
            # Generic error checking for unknown games
            if echo "$recent_logs" | grep -qi "fatal\|error\|crash"; then
                if [[ "$VERBOSE" == "true" ]]; then
                    log_error "✗ Error patterns found in logs"
                fi
                return 1
            fi
            ;;
    esac
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "ℹ No obvious error patterns in recent logs"
    fi
    return 0
}

check_network_connectivity() {
    local container_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Checking network connectivity..."
    fi
    
    # Get container network information
    local port_info
    port_info=$(docker port "$container_name" 2>/dev/null || echo "")
    
    if [[ -z "$port_info" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "ℹ No exposed ports found"
        fi
        return 0
    fi
    
    # Check if ports are accessible
    local port_accessible=false
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local port_mapping
            port_mapping=$(echo "$line" | grep -o '0\.0\.0\.0:[0-9]*' | cut -d: -f2)
            if [[ -n "$port_mapping" ]]; then
                if nc -z localhost "$port_mapping" 2>/dev/null; then
                    if [[ "$VERBOSE" == "true" ]]; then
                        log_info "✓ Port $port_mapping is accessible"
                    fi
                    port_accessible=true
                else
                    if [[ "$VERBOSE" == "true" ]]; then
                        log_info "⚠ Port $port_mapping is not responding"
                    fi
                fi
            fi
        fi
    done <<< "$port_info"
    
    if [[ "$port_accessible" == "true" ]]; then
        return 0
    else
        log_error "✗ No ports are responding"
        return 1
    fi
}

check_resource_usage() {
    local container_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Checking resource usage..."
    fi
    
    # Get container stats
    local stats
    stats=$(docker stats --no-stream --format "table {{.CPUPerc}}\t{{.MemUsage}}" "$container_name" 2>/dev/null || echo "")
    
    if [[ -n "$stats" ]]; then
        local cpu_usage mem_usage
        cpu_usage=$(echo "$stats" | tail -n1 | awk '{print $1}' | tr -d '%')
        mem_usage=$(echo "$stats" | tail -n1 | awk '{print $2}')
        
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "✓ CPU Usage: ${cpu_usage}%"
            log_info "✓ Memory Usage: ${mem_usage}"
        fi
        
        # Basic resource usage validation (warn if CPU > 90%)
        if [[ -n "$cpu_usage" ]] && (( $(echo "$cpu_usage > 90" | bc -l) )); then
            log_warn "⚠ High CPU usage detected: ${cpu_usage}%"
        fi
    else
        if [[ "$VERBOSE" == "true" ]]; then
            log_info "ℹ Could not retrieve resource usage statistics"
        fi
    fi
    
    return 0
}

run_game_specific_health_checks() {
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Running game-specific health checks..."
    fi
    
    # Delegate to game plugin health check
    if ! "$PROJECT_ROOT/scripts/core/server-manager.sh" health --game "$GAME" --context "$CONTEXT" --env "$ENVIRONMENT" --quiet; then
        log_error "✗ Game-specific health check failed"
        return 1
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "✓ Game-specific health checks passed"
    fi
    return 0
}

wait_for_startup() {
    local retry_count=0
    local max_wait_time=$TIMEOUT
    local start_time
    start_time=$(date +%s)
    
    log_info "Waiting for server to become healthy (timeout: ${TIMEOUT}s)..."
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        local current_time
        current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        if [[ $elapsed_time -ge $max_wait_time ]]; then
            log_error "Health check timeout reached (${TIMEOUT}s)"
            return 1
        fi
        
        # Check container health
        local health_result
        check_container_health
        health_result=$?
        
        if [[ $health_result -eq 0 ]]; then
            return 0
        elif [[ $health_result -eq 2 ]]; then
            # Still starting, wait a bit longer
            if [[ "$VERBOSE" == "true" ]]; then
                log_info "Server still initializing, waiting..."
            fi
            sleep 5
            continue
        else
            # Health check failed, retry
            ((retry_count++))
            if [[ $retry_count -lt $MAX_RETRIES ]]; then
                log_warn "Health check failed, retrying ($retry_count/$MAX_RETRIES)..."
                sleep 10
            fi
        fi
    done
    
    log_error "Health check failed after $MAX_RETRIES retries"
    return 1
}

show_health_summary() {
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    log_info "=== Health Check Summary ==="
    log_info "Server: $server_name"
    log_info "Environment: $ENVIRONMENT"
    log_info "Status: Healthy"
    log_info "Timestamp: $(date)"
    log_info "=========================="
}

main() {
    parse_arguments "$@"
    
    local server_name="${GAME}-${ENVIRONMENT}-${CONTEXT}"
    
    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Starting health check for server: $server_name"
    fi
    
    # Basic checks
    if ! check_container_running; then
        exit 1
    fi
    
    # Wait for startup if needed
    if ! wait_for_startup; then
        exit 1
    fi
    
    # Detailed health checks
    if ! check_container_logs; then
        exit 1
    fi
    
    if ! check_network_connectivity; then
        exit 1
    fi
    
    # Resource usage check (warning only)
    check_resource_usage
    
    # Game-specific checks
    if ! run_game_specific_health_checks; then
        exit 1
    fi
    
    # Show summary
    show_health_summary
    
    log_info "Health check completed successfully"
}

# Run main function with all arguments
main "$@"