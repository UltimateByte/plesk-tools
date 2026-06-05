#!/bin/bash
# =============================================================================
# uptime-kuma-sync.sh - Sync Plesk domains to Uptime Kuma monitors
# Single entry point: install, update, sync, cleanup, list, cron
# Author: LRob - https://www.lrob.fr/
# License: GNU General Public License v3.0
# =============================================================================

main() {

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
# Silence pip's "a new release is available" notice (cosmetic, clutters logs/cron)
export PIP_DISABLE_PIP_VERSION_CHECK=1

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

# Off-server detection config block (appended to new and upgraded .env files).
print_offserver_config() {
    cat <<'ENVEOF'

# -----------------------------------------------------------------------------
# Off-server detection (evaluated during --cleanup only)
# -----------------------------------------------------------------------------
# A domain is "off-server" when it no longer resolves (via DNS_RESOLVER) to any
# of this server's interface IPs. Action to take for such domains:
#   report  - only log off-server domains, change nothing (safe default)
#   move    - move the monitor into the off-server group and pause it
#   pause   - pause the monitor in place (no group change)
#   delete  - delete the monitor (like a domain removed from Plesk)
#   off     - disable the feature entirely (skip DNS resolution)
# move/pause are reversible: when a domain points back here, the monitor is
# resumed (and moved back to the main group).
OFFSERVER_ACTION="report"

# Off-server group label (used when OFFSERVER_ACTION=move). One top-level group
# is auto-created per owner that has off-server sites, named "<reseller> <label>"
# (e.g. "digisense Off-server"), or just "<label>" for admin/direct domains.
# (Kuma has no usable nested subgroups, hence top-level sibling groups.)
OFFSERVER_GROUP_NAME="Off-server"
# Override: set to a numeric group ID to send ALL off-server monitors to one
# existing group as-is (no per-owner groups). Leave empty for the per-owner ones.
OFFSERVER_GROUP_ID=""
# Placement of auto-created off-server groups: empty = top level (root), or a
# numeric group ID to nest them under.
OFFSERVER_GROUP_PARENT=""

# Cosmetic suffix appended to a monitor's name while it is off-server (move/pause
# actions). Stripped automatically when matching, so it never creates duplicates.
# Set empty to disable renaming.
OFFSERVER_NAME_SUFFIX=" [off-server]"
# Suffix marking a monitor the tool paused because the domain no longer resolves
# (NXDOMAIN / no address). Kept in place, just paused; resumed when it resolves again.
UNRESOLVED_NAME_SUFFIX=" [no-dns]"

# Public DNS resolver used to check where domains point (avoids local bind,
# which on a Plesk DNS master would always answer with the local IP).
DNS_RESOLVER="1.1.1.1"
ENVEOF
}

# Grouping / suspended-domain config block.
print_grouping_config() {
    cat <<'ENVEOF'

# -----------------------------------------------------------------------------
# Monitor grouping by owner
# -----------------------------------------------------------------------------
# How to lay out monitors into Uptime Kuma groups:
#   flat        - all monitors in the main group (PARENT_GROUP_ID)
#   by-reseller - one group per reseller (its domains + its clients' domains);
#                 admin-owned and direct-customer domains stay in the main group
GROUPING_MODE="by-reseller"
# Optional prefix for reseller group names (e.g. "Reseller: "). Empty = the
# reseller's Plesk login is used as-is.
RESELLER_GROUP_PREFIX=""
# Placement of auto-created reseller groups: empty = top level (root),
# or a numeric group ID to nest them under.
RESELLER_GROUP_PARENT=""

# -----------------------------------------------------------------------------
# Suspended domains (Plesk status 16/32)
# -----------------------------------------------------------------------------
# Plesk does not distinguish accidental from deliberate suspension, so one policy:
#   keep   - keep monitoring and alerting (catch accidental suspensions) [default]
#   pause  - keep the monitor but pause it (no alert), resumed on reactivation
#   delete - do not monitor suspended domains (recreated when reactivated)
SUSPENDED_ACTION="keep"
# Cosmetic suffix marking a monitor the tool paused for suspension (SUSPENDED_ACTION=pause).
# Also serves as the ownership marker so the tool never resumes a manual pause.
SUSPENDED_NAME_SUFFIX=" [suspended]"
ENVEOF
}

# Add any config keys missing from an existing .env (idempotent, run on --update).
ensure_env_keys() {
    [[ -f "$ENV_FILE" ]] || return 0
    local added=0
    if ! grep -q '^OFFSERVER_ACTION=' "$ENV_FILE"; then
        print_offserver_config >> "$ENV_FILE"
        added=1
    fi
    if ! grep -q '^OFFSERVER_NAME_SUFFIX=' "$ENV_FILE"; then
        printf '\n# Cosmetic suffix on a monitor name while off-server (stripped when matching).\nOFFSERVER_NAME_SUFFIX=" [off-server]"\n' >> "$ENV_FILE"
        added=1
    fi
    if ! grep -q '^UNRESOLVED_NAME_SUFFIX=' "$ENV_FILE"; then
        printf '\n# Suffix marking a monitor paused because the domain no longer resolves (NXDOMAIN).\nUNRESOLVED_NAME_SUFFIX=" [no-dns]"\n' >> "$ENV_FILE"
        added=1
    fi
    if ! grep -q '^GROUPING_MODE=' "$ENV_FILE"; then
        print_grouping_config >> "$ENV_FILE"
        added=1
    fi
    if ! grep -q '^SUSPENDED_NAME_SUFFIX=' "$ENV_FILE"; then
        printf '\n# Cosmetic suffix marking a monitor the tool paused for suspension (ownership marker).\nSUSPENDED_NAME_SUFFIX=" [suspended]"\n' >> "$ENV_FILE"
        added=1
    fi
    [[ $added -eq 1 ]] && log "Added new settings to $ENV_FILE (defaults applied, review them)"
    return 0
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

    mkdir -p "$INSTALL_DIR"

    # Create .env interactively if not present
    if [[ ! -f "$ENV_FILE" ]]; then
        log "No config file found, starting interactive setup..."
        echo ""
        read -rp "Uptime Kuma URL (e.g. https://kuma.example.com): " input_url
        read -rp "Uptime Kuma username: " input_user
        read -rsp "Uptime Kuma password: " input_pass
        echo ""

        # Install deps first so we can query Kuma
        setup_venv

        # Download Python script
        download_python_script

        # Query Kuma for available groups and notifications
        echo ""
        log "Connecting to Uptime Kuma to list available groups and notifications..."
        local info_json
        info_json=$(cat <<PYEOF
{
    "url": "${input_url}",
    "username": "${input_user}",
    "password": "${input_pass}",
    "login_timeout": 15
}
PYEOF
)
        echo ""
        "$VENV_DIR/bin/python" -u "$PYTHON_SCRIPT" --action info --config "$info_json" 2>&1 || true
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
MONITOR_INTERVAL=300
MONITOR_RETRY_INTERVAL=150
MONITOR_TIMEOUT=30
MONITOR_MAX_RETRIES=3
MONITOR_MAX_REDIRECTS=10

# Domain exclusion patterns (grep -E pattern, matched against domain name)
EXCLUDE_PATTERN="\.plesk\.page$"

# Cron schedule (used by --cron)
CRON_SCHEDULE="0 10 * * *"

# Log retention in days
LOG_RETENTION_DAYS=30

# Login timeout in seconds per attempt (3 attempts max)
LOGIN_TIMEOUT=15
ENVEOF

        print_offserver_config >> "$ENV_FILE"
        print_grouping_config >> "$ENV_FILE"

        chmod 600 "$ENV_FILE"
        log "Config saved to $ENV_FILE"
    fi

    # Ensure venv and deps (idempotent)
    setup_venv

    # Ensure Python script
    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        download_python_script
    fi

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

    # Update self (download to temp then mv for atomic replace)
    log "Downloading latest bash script..."
    local tmp
    tmp=$(mktemp)
    if curl -fsSL "$GITHUB_RAW/uptime-kuma-sync.sh" -o "$tmp"; then
        chmod +x "$tmp"
        mv "$tmp" "$SELF_SCRIPT"
        log "Bash script updated"
    else
        rm -f "$tmp"
        log "WARNING: Failed to download bash script update"
    fi

    # Upgrade pip itself, then deps
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install --upgrade "python-socketio[client]" websocket-client dnspython -q

    # Add any newly-introduced config keys to an existing .env
    ensure_env_keys

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

setup_venv() {
    # Install python3-venv if needed
    if ! python3 -m venv --help &>/dev/null; then
        log "Installing python3-venv..."
        apt update
        apt install -y python3-venv
    fi

    if [[ ! -d "$VENV_DIR" ]]; then
        log "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR"
    fi

    log "Installing Python dependencies..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install --upgrade "python-socketio[client]" websocket-client dnspython -q
}

# -----------------------------------------------------------------------------
# Local server IPs (used by the Python off-server detection during --cleanup)
# -----------------------------------------------------------------------------
# Collect this server's global (public-facing) interface IPs as a JSON array.
# Uses iproute2 (`ip`), present on every modern distro - no package install.
get_local_ips_json() {
    local ips
    ips=$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    local first=1 ip out="["
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
        out+="\"$ip\""
    done <<< "$ips"
    out+="]"
    echo "$out"
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

    # Query columns: name, seoRedirect, status (0=active, 16/32=suspended),
    # reseller login. reseller is queried LAST and is the only field that can be
    # empty (admin/direct domains) - keeping it last avoids the bash whitespace-IFS
    # field-collapse that would otherwise shift status into the reseller slot.
    local raw
    # Main domains with seo redirect preference + status + reseller
    raw=$(plesk db -Ne "SELECT d.name, COALESCE(p.val, 'none'), d.status, COALESCE(v.login, '') FROM domains d LEFT JOIN dom_param p ON d.id = p.dom_id AND p.param = 'seoRedirect' LEFT JOIN clients v ON d.vendor_id = v.id AND v.type = 'reseller' WHERE d.status IN (0, 16, 32) AND d.htype IN ('vrt_hst', 'std_fwd', 'frm_fwd')" | cat)

    # Domain aliases with web hosting enabled (reseller/status inherited from parent)
    local aliases
    aliases=$(plesk db -Ne "SELECT da.name, 'none', d.status, COALESCE(v.login, '') FROM domain_aliases da JOIN domains d ON da.dom_id = d.id LEFT JOIN clients v ON d.vendor_id = v.id AND v.type = 'reseller' WHERE da.status = 0 AND da.web = 'true' AND d.status IN (0, 16, 32)" | cat)

    # Merge both lists
    if [[ -n "$aliases" ]]; then
        raw=$(printf '%s\n%s' "$raw" "$aliases")
    fi

    : > "$DOMAINS_FILE"
    local count=0
    local excluded=0
    local suspended=0

    # Read order matches the query (status before the possibly-empty reseller);
    # the output file keeps the logical order: domain<TAB>seo<TAB>url<TAB>reseller<TAB>status
    while IFS=$'\t' read -r domain seo_redirect status reseller; do
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

        [[ "${status:-0}" != "0" ]] && suspended=$((suspended + 1))

        printf '%s\t%s\t%s\t%s\t%s\n' "$domain" "$seo_redirect" "$url" "$reseller" "${status:-0}" >> "$DOMAINS_FILE"
        count=$((count + 1))
    done <<< "$raw"

    log "Found $count domains + aliases ($excluded excluded, $suspended suspended)"
}

# -----------------------------------------------------------------------------
# Python Script Invocation
# -----------------------------------------------------------------------------
run_python() {
    local action="$1"
    shift

    local local_ips_json
    local_ips_json=$(get_local_ips_json)

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
    "monitor_max_redirects": $MONITOR_MAX_REDIRECTS,
    "login_timeout": ${LOGIN_TIMEOUT:-15},
    "offserver_action": "${OFFSERVER_ACTION:-report}",
    "offserver_group_name": "${OFFSERVER_GROUP_NAME:-Off-server}",
    "offserver_group_id": ${OFFSERVER_GROUP_ID:-null},
    "offserver_group_parent": ${OFFSERVER_GROUP_PARENT:-null},
    "offserver_name_suffix": "${OFFSERVER_NAME_SUFFIX:- [off-server]}",
    "unresolved_name_suffix": "${UNRESOLVED_NAME_SUFFIX:- [no-dns]}",
    "grouping_mode": "${GROUPING_MODE:-by-reseller}",
    "reseller_group_prefix": "${RESELLER_GROUP_PREFIX:-}",
    "reseller_group_parent": ${RESELLER_GROUP_PARENT:-null},
    "suspended_action": "${SUSPENDED_ACTION:-keep}",
    "suspended_name_suffix": "${SUSPENDED_NAME_SUFFIX:- [suspended]}",
    "dns_resolver": "${DNS_RESOLVER:-1.1.1.1}",
    "local_ips": $local_ips_json
}
PYEOF
)

    "$VENV_DIR/bin/python" -u "$PYTHON_SCRIPT" --action "$action" --config "$config_json" "$@" 2>&1 | tee -a "$LOG_FILE"
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
    local dry_run="${1:-false}"
    check_config
    ensure_installed

    list_plesk_domains

    if [[ "$dry_run" == "true" ]]; then
        run_python cleanup --dry-run
    else
        run_python cleanup
    fi
}

cmd_cron() {
    load_config
    local schedule="${CRON_SCHEDULE:-0 10 * * *}"
    local cron_marker="# uptime-kuma-sync"

    # Remove existing
    crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null || true

    # Add sync + cleanup
    local cron_line="$schedule $SELF_SCRIPT --sync && $SELF_SCRIPT --cleanup"
    (crontab -l 2>/dev/null; echo "$cron_line $cron_marker") | crontab -
    log "Cron installed: $cron_line"
}

cmd_uncron() {
    local cron_marker="# uptime-kuma-sync"
    crontab -l 2>/dev/null | grep -v "$cron_marker" | crontab - 2>/dev/null || true
    log "Cron removed"
}

cmd_info() {
    check_config
    ensure_installed
    run_python info
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
    --sync              List Plesk domains and create missing monitors
    --sync --dry-run    Preview what sync would do without making changes
    --list              List current monitors in the Uptime Kuma group
    --cleanup           Remove obsolete monitors
    --cleanup --dry-run Preview monitors that would be removed
    --info              Show available groups and notifications
    --cron              Install cron job (sync + cleanup)
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
    --info)             cmd_info ;;
    --cleanup)
        if [[ "${2:-}" == "--dry-run" ]]; then
            cmd_cleanup true
        else
            cmd_cleanup false
        fi
        ;;
    --cron)             cmd_cron ;;
    --uncron)           cmd_uncron ;;
    -h|--help)          usage ;;
    *)                  usage ;;
esac

}
main "$@"
