#!/bin/bash
#
# ARK cluster volume restore — ad-hoc wrapper around ark_restore_cluster.
# Cluster restore is rare and ARK-specific, so it lives outside the universal
# server-manager CLI to avoid teaching that CLI about env-only operations.
#
# Usage:
#   ark-cluster-restore.sh --env <staging|production> --backup <file> [--force]
#   ark-cluster-restore.sh --env <env> --list
#
# All ARK instances in <env> must be stopped before restore. The script will
# refuse if any are running.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/shared/server-utils.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/games/ark/scripts/game-specific-logic.sh"

ENV=""
BACKUP=""
FORCE=false
LIST_ONLY=false

usage() {
    cat <<USAGE
Usage:
  $0 --env <staging|production> --backup <file> [--force]
  $0 --env <staging|production> --list

Options:
  --env <name>       Target environment (required)
  --backup <file>    Backup filename (filename or absolute path) — for restore
  --list             List available cluster backups for the env and exit
  --force            Skip confirmation prompt

The cluster volume is shared across all ARK instances in the env. Every
ARK instance in <env> must be stopped before running this script.
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV="$2"; shift 2 ;;
        --backup) BACKUP="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --list) LIST_ONLY=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "$ENV" ]]; then
    log_error "--env is required"
    usage
fi

if ! validate_environment "$ENV"; then
    exit 1
fi

backup_dir="${REPO_ROOT}/backups/${ENV}/_cluster"

if [[ "$LIST_ONLY" == true ]]; then
    if [[ ! -d "$backup_dir" ]]; then
        echo "No cluster backups found for $ENV (directory missing: $backup_dir)"
        exit 0
    fi
    echo "Cluster backups for ark/${ENV}:"
    find "$backup_dir" -maxdepth 1 -name "*.tar.gz" -type f -printf '%T@ %TY-%Tm-%Td %TH:%TM  %f  (%s bytes)\n' \
        | sort -rn | cut -d' ' -f2-
    exit 0
fi

if [[ -z "$BACKUP" ]]; then
    log_error "--backup is required for restore (or use --list)"
    usage
fi

if [[ "$FORCE" != true ]]; then
    echo
    echo "About to restore the ARK cluster volume for environment: ${ENV}"
    echo "Backup file: ${BACKUP}"
    echo
    echo "This will WIPE the current cluster volume and replace it with the"
    echo "backup contents. All player uploads currently in the cluster will"
    echo "be replaced. Survivors/dinos/items uploaded between the backup"
    echo "timestamp and now will be lost."
    echo
    read -r -p "Type 'restore' to confirm: " confirm
    if [[ "$confirm" != "restore" ]]; then
        log_info "Aborted by user"
        exit 0
    fi
fi

ark_restore_cluster "$ENV" "$BACKUP"
