#!/bin/bash
# =============================================================================
# uptime-kuma-sync.sh - Sync Plesk domains to Uptime Kuma monitors
# Single entry point: install, update, sync, cleanup, list, cron
# Author: LRob - https://www.lrob.fr/
# License: GNU General Public License v3.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
INSTALL_DIR="/opt/uptime-kuma-sync"
ENV_FILE="$INSTALL_DIR/.env"
PYTHON_SCRIPT="$INSTALL_DIR/uptime-kuma-sync.py"
VENV_DIR="$INSTALL_DIR/venv"
DOMAINS_FILE="$INSTALL_DIR/domains-list"
LOG_FILE="$INSTALL_DIR/uptime-kuma-sync.log"
SELF_SCRIPT="$INSTALL_DIR/uptime-kuma-sync.sh"

GITHUB_RAW="https://raw.githubusercontent.com/UltimateByte/plesk-tools/refs/heads/main/uptime_kuma_sync"

# -----------------------------------------------------------------------------
# Load config
# -----------------------------------------------------------------------------
load_config() {
    if [[ ! -f "$ENV_FILE" ]]; then
        return 1
    fi
    # shellcheck source=/dev/null
    source "$ENV_FILE"
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_trim() {
    [[ ! -f "$LOG_FILE" ]] && return
    local cutoff_date
    cutoff_date=$(date -d "-${LOG_RETENTION_DAYS} days" '+%Y-%m-%d' 2>/dev/null || date -v-${LOG_RETENTION_DAYS}d '+%Y-%m-%d' 2>/dev/null || return 0)
    local tmp
    tmp=$(mktemp)
    awk -v cutoff="$cutoff_date" '$0 ~ /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}/ { date=substr($0,2,10); if (date >= cutoff) print; next } { print }' "$LOG_FILE" > "$tmp"
    mv "$tmp" "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root"
        exit 1
    fi
}

check_config() {
    if ! load_config; then
        log "ERROR: Config file not found: $ENV_FILE"
        log "Run: $0 --install"
        exit 1
    fi
    if [[ "$UPTIME_KUMA_URL" == "https://your-uptime-kuma-instance.com" ]] || [[ -z "$USERNAME" ]] || [[ -z "$PASSWORD" ]]; then
        log "ERROR: Edit $ENV_FILE before running."
        exit 1
    fi
}

ensure_installed() {
    if [[ ! -f "$PYTHON_SCRIPT" ]] || [[ ! -d "$VENV_DIR" ]]; then
        log "Not installed yet, running auto-install..."
        cmd_install
    fi
}

# -----------------------------------------------------------------------------
# Install & Update
# -----------------------------------------------------------------------------
cmd_install() {
    log "=== Installing uptime-kuma-sync ==="

    # Install python3-venv if needed
    if ! python3 -m venv --help &>/dev/null; then
        log "Installing python3-venv..."
        apt update
        apt install -y python3-venv
    fi

    mkdir -p "$INSTALL_DIR"

    # Create .env interactively if not present
    if [[ ! -f "$ENV_FILE" ]]; then
        log "No config file found, starting interactive setup..."
        echo ""
        read -rp "Uptime Kuma URL (e.g. https://kuma.example.com): " input_url
        read -rp "Uptime Kuma username: " input_user
        read -rsp "Uptime Kuma password: " input_pass
        echo ""
        read -rp "Parent group ID [1]: " input_group
        input_group="${input_group:-1}"
        read -rp "Notification IDs (space-separated) [1]: " input_notif
        input_notif="${input_notif:-1}"

        cat > "$ENV_FILE" <<ENVEOF
# =============================================================================
# uptime-kuma-sync configuration
# =============================================================================

# Uptime Kuma connection
UPTIME_KUMA_URL="${input_url}"
USERNAME="${input_user}"
PASSWORD="${input_pass}"

# Uptime Kuma monitor group parent ID
PARENT_GROUP_ID=${input_group}

# Default notification IDs to attach (space-separated, e.g., "1 2 3")
DEFAULT_NOTIFICATION_IDS="${input_notif}"

# Monitor defaults
MONITOR_INTERVAL=60
MONITOR_RETRY_INTERVAL=60
MONITOR_TIMEOUT=30
MONITOR_MAX_RETRIES=1
MONITOR_MAX_REDIRECTS=10

# Domain exclusion patterns (grep -E pattern, matched against domain name)
EXCLUDE_PATTERN="\.plesk\.page$"

# Cron schedule (used by --cron)
CRON_SCHEDULE="0 10 * * *"

# Log retention in days
LOG_RETENTION_DAYS=30
ENVEOF

        chmod 600 "$ENV_FILE"
        log "Config saved to $ENV_FILE"
    fi

    # Create venv
    if [[ ! -d "$VENV_DIR" ]]; then
        log "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR"
    fi

    # Install/upgrade dependencies
    log "Installing Python dependencies..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install --upgrade "python-socketio[client]" websocket-client -q

    # Download Python script
    download_python_script

    # Copy self to install dir if not already there
    local self_path
    self_path="$(realpath "$0")"
    if [[ "$self_path" != "$SELF_SCRIPT" ]]; then
        cp "$self_path" "$SELF_SCRIPT"
        chmod +x "$SELF_SCRIPT"
        log "Copied self to $SELF_SCRIPT"
    fi

    # Symlink
    ln -sf "$SELF_SCRIPT" /usr/local/bin/uptime-kuma-sync
    log "Created symlink: /usr/local/bin/uptime-kuma-sync"

    log "=== Installation complete ==="
}

cmd_update() {
    log "=== Updating uptime-kuma-sync ==="

    # Re-download Python script
    download_python_script

    # Update self
    log "Downloading latest bash script..."
    if curl -fsSL "$GITHUB_RAW/uptime-kuma-sync.sh" -o "$SELF_SCRIPT"; then
        chmod +x "$SELF_SCRIPT"
        log "Bash script updated"
    else
        log "WARNING: Failed to download bash script update"
    fi

    # Upgrade pip deps
    "$VENV_DIR/bin/pip" install --upgrade "python-socketio[client]" websocket-client -q

    log "=== Update complete ==="
}

download_python_script() {
    log "Downloading Python script..."
    if curl -fsSL "$GITHUB_RAW/uptime-kuma-sync.py" -o "$PYTHON_SCRIPT"; then
        chmod +x "$PYTHON_SCRIPT"
        log "Python script downloaded"
    else
        log "ERROR: Failed to download Python script"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Plesk Domain Listing
# -----------------------------------------------------------------------------
list_plesk_domains() {
    log "Listing active Plesk domains..."

    if ! command -v plesk &>/dev/null; then
        log "ERROR: plesk command not found. Is this a Plesk server?"
        exit 1
    fi

    local raw
    raw=$(plesk db -Ne "SELECT d.name, COALESCE(p.val, 'none') FROM domains d LEFT JOIN dom_param p ON d.id = p.dom_id AND p.param = 'seoRedirect' WHERE d.status = 0 AND d.htype = 'vrt_hst'" | cat)

    : > "$DOMAINS_FILE"
    local count=0
    local excluded=0

    while IFS=$'\t' read -r domain seo_redirect; do
        [[ -z "$domain" ]] && continue

        # Skip excluded patterns
        if [[ -n "${EXCLUDE_PATTERN:-}" ]] && echo "$domain" | grep -qE "$EXCLUDE_PATTERN"; then
            excluded=$((excluded + 1))
            continue
        fi

        local url
        if [[ "$seo_redirect" == "www" ]]; then
            url="https://www.${domain}/"
        else
            url="https://${domain}/"
        fi

        echo "$domain $seo_redirect $url" >> "$DOMAINS_FILE"
        count=$((count + 1))
    done <<< "$raw"

    log "Found $count domains ($excluded excluded)"
}

# -----------------------------------------------------------------------------
# Python Script Invocation
# -----------------------------------------------------------------------------
run_python() {
    local action="$1"
    shift

    local config_json
    config_json=$(cat <<PYEOF
{
    "url": "$UPTIME_KUMA_URL",
    "username": "$USERNAME",
    "password": "$PASSWORD",
    "domains_file": "$DOMAINS_FILE",
    "parent_group_id": $PARENT_GROUP_ID,
    "notification_ids": [$(echo "$DEFAULT_NOTIFICATION_IDS" | tr ' ' ',')],
    "monitor_interval": $MONITOR_INTERVAL,
    "monitor_retry_interval": $MONITOR_RETRY_INTERVAL,
    "monitor_timeout": $MONITOR_TIMEOUT,
    "monitor_max_retries": $MONITOR_MAX_RETRIES,
    "monitor_max_redirects": $MONITOR_MAX_REDIRECTS
}
PYEOF
)

    "$VENV_DIR/bin/python" "$PYTHON_SCRIPT" --action "$action" --config "$config_json" "$@" 2>&1 | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_sync() {
    local dry_run="${1:-false}"
    check_config
    ensure_installed

    log "=== Sync started ==="
    log_trim

    list_plesk_domains

    if [[ "$dry_run" == "true" ]]; then
        run_python sync --dry-run
    else
        run_python sync
    fi

    log "=== Sync complete ==="
}

cmd_list() {
    check_config
    ensure_installed
    run_python list
}

cmd_cleanup() {
    check_config
    ensure_installed

    list_plesk_domains
    run_python cleanup
}

cmd_cleanup_confirm() {
    check_config
    ensure_installed

    list_plesk_domains
    run_python cleanup-confirm
}

cmd_cron() {
    load_config
    local cron_line="${CRON_SCHEDULE:-0 10 * * *} $SELF_SCRIPT --sync"
    local cron_marker="# uptime-kuma-sync"

    # Remove existing
    crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null || true

    # Add new
    (crontab -l 2>/dev/null; echo "$cron_line $cron_marker") | crontab -
    log "Cron installed: $cron_line"
}

cmd_uncron() {
    local cron_marker="# uptime-kuma-sync"
    crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null || true
    log "Cron removed"
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTION]

Sync Plesk domains to Uptime Kuma monitors.

Commands:
    --install           Install/setup Python venv and dependencies
    --update            Re-download scripts from GitHub (preserves .env)
    --sync              List Plesk domains and sync to Uptime Kuma
    --sync --dry-run    Preview what sync would do without making changes
    --list              List current monitors in the Uptime Kuma group
    --cleanup           Preview monitors that would be removed
    --cleanup-confirm   Remove obsolete monitors
    --cron              Install cron job
    --uncron            Remove cron job
    -h, --help          Show this help

Config: $ENV_FILE
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
check_root

# Ensure install dir exists
mkdir -p "$INSTALL_DIR"

case "${1:---help}" in
    --install)          cmd_install ;;
    --update)           cmd_update ;;
    --sync)
        if [[ "${2:-}" == "--dry-run" ]]; then
            cmd_sync true
        else
            cmd_sync false
        fi
        ;;
    --list)             cmd_list ;;
    --cleanup)          cmd_cleanup ;;
    --cleanup-confirm)  cmd_cleanup_confirm ;;
    --cron)             cmd_cron ;;
    --uncron)           cmd_uncron ;;
    -h|--help)          usage ;;
    *)                  usage ;;
esac
