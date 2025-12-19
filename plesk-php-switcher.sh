#!/bin/bash
#===============================================================================
#
#   Plesk PHP Version Switcher
#   Bulk switch PHP versions for hosted domains
#
#   Author: Robin Labadie - https://www.lrob.fr
#   License: MIT
#
#===============================================================================

set -euo pipefail

readonly SCRIPT_NAME="plesk-php-switcher"
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/${SCRIPT_NAME}"
readonly LOG_FILE="${LOG_DIR}/switch-$(date +%Y%m%d-%H%M%S).log"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------

init_log() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log "INFO" "Session started - ${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

print_info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
print_success() { echo -e "${GREEN}✓${NC}  $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC}  $1"; }
print_error()   { echo -e "${RED}✗${NC}  $1"; }

#-------------------------------------------------------------------------------
# Checks
#-------------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_plesk() {
    if ! command -v plesk &> /dev/null; then
        print_error "Plesk is not installed on this system"
        exit 1
    fi
}

#-------------------------------------------------------------------------------
# PHP Detection
#-------------------------------------------------------------------------------

get_available_handlers() {
    plesk bin php_handler --list 2>/dev/null | \
        awk '/^[[:space:]]*plesk-php[0-9]+-/ && /enabled$/ {print $1}' | sort -u
}

get_used_handlers() {
    plesk db "SELECT DISTINCT h.php_handler_id FROM hosting h WHERE h.php_handler_id LIKE 'plesk-php%'" 2>/dev/null | \
        tail -n +4 | awk -F'|' '/\|/ && !/^\+/ {gsub(/[ \t]+/, "", $2); if ($2 != "") print $2}' | sort -u
}

get_domains_by_handler() {
    local handler="$1"
    plesk db "SELECT d.name FROM domains d JOIN hosting h ON d.id = h.dom_id WHERE h.php_handler_id = '${handler}'" 2>/dev/null | \
        tail -n +4 | awk -F'|' '/\|/ && !/^\+/ {gsub(/[ \t]+/, "", $2); if ($2 != "") print $2}'
}

count_domains_by_handler() {
    local handler="$1"
    get_domains_by_handler "$handler" | wc -l
}

#-------------------------------------------------------------------------------
# Display
#-------------------------------------------------------------------------------

show_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           Plesk PHP Version Switcher v${SCRIPT_VERSION}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}           Author: Robin Labadie - lrob.fr                    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_current_usage() {
    echo -e "${YELLOW}═══ Current PHP Usage ═══${NC}"
    echo ""

    local handlers
    handlers=$(get_used_handlers)

    if [[ -z "$handlers" ]]; then
        print_warning "No domains with PHP handlers found"
        return
    fi

    printf "  %-35s %s\n" "HANDLER" "DOMAINS"
    printf "  %-35s %s\n" "───────────────────────────────────" "───────"

    while IFS= read -r handler; do
        local count
        count=$(count_domains_by_handler "$handler")
        printf "  %-35s %s\n" "$handler" "$count"
    done <<< "$handlers"

    echo ""
}

show_available_handlers() {
    echo -e "${YELLOW}═══ Available PHP Handlers ═══${NC}"
    echo ""

    local handlers
    handlers=$(get_available_handlers)

    local i=1
    while IFS= read -r handler; do
        echo "  [$i] $handler"
        ((i++))
    done <<< "$handlers"

    echo ""
}

#-------------------------------------------------------------------------------
# Selection
#-------------------------------------------------------------------------------

select_handler() {
    local prompt="$1"
    local source_mode="${2:-false}"

    local handlers
    if [[ "$source_mode" == "true" ]]; then
        handlers=$(get_used_handlers)
    else
        handlers=$(get_available_handlers)
    fi

    local handlers_array=()

    while IFS= read -r handler; do
        [[ -z "$handler" ]] && continue
        handlers_array+=("$handler")
    done <<< "$handlers"

    local count=${#handlers_array[@]}

    if [[ $count -eq 0 ]]; then
        print_error "No handlers found" >&2
        exit 1
    fi

    echo -e "${CYAN}${prompt}${NC}" >&2
    echo "" >&2

    for i in "${!handlers_array[@]}"; do
        local num=$((i + 1))
        local used_count
        used_count=$(count_domains_by_handler "${handlers_array[$i]}")
        if [[ $used_count -gt 0 ]]; then
            echo "  [$num] ${handlers_array[$i]} (${used_count} domains)" >&2
        else
            echo "  [$num] ${handlers_array[$i]}" >&2
        fi
    done

    echo "" >&2
    read -rp "  Enter number [1-${count}]: " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$count" ]]; then
        print_error "Invalid selection"
        exit 1
    fi

    echo "${handlers_array[$((choice - 1))]}"
}

#-------------------------------------------------------------------------------
# Switch Operations
#-------------------------------------------------------------------------------

switch_domain() {
    local domain="$1"
    local target_handler="$2"
    local old_handler="$3"

    log "SWITCH" "Domain: ${domain} | ${old_handler} -> ${target_handler}"

    if plesk bin domain -u "$domain" -php_handler_id "$target_handler" &>> "$LOG_FILE"; then
        print_success "${domain}"
        log "SUCCESS" "Domain ${domain} switched successfully"
        return 0
    else
        print_error "${domain} - FAILED (see log)"
        log "ERROR" "Domain ${domain} switch failed"
        return 1
    fi
}

perform_bulk_switch() {
    local source_handler="$1"
    local target_handler="$2"

    local domains
    domains=$(get_domains_by_handler "$source_handler")

    if [[ -z "$domains" ]]; then
        print_warning "No domains found using ${source_handler}"
        return
    fi

    local total
    total=$(echo "$domains" | wc -l)

    echo ""
    echo -e "${YELLOW}═══ Domains to Switch ═══${NC}"
    echo ""
    echo "$domains" | sed 's/^/  • /'
    echo ""
    echo -e "  Total: ${CYAN}${total}${NC} domain(s)"
    echo -e "  From:  ${RED}${source_handler}${NC}"
    echo -e "  To:    ${GREEN}${target_handler}${NC}"
    echo ""

    log "INFO" "Bulk switch: ${source_handler} -> ${target_handler} (${total} domains)"

    # Rollback file
    local rollback_file="${LOG_DIR}/rollback-$(date +%Y%m%d-%H%M%S).sh"
    {
        echo "#!/bin/bash"
        echo "# Rollback script - Generated $(date)"
        echo "# Source: ${source_handler}"
        echo "# Target: ${target_handler}"
        echo ""
    } > "$rollback_file"
    chmod +x "$rollback_file"

    read -rp "  Proceed with switch? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warning "Operation cancelled"
        log "INFO" "Operation cancelled by user"
        return
    fi

    echo ""
    echo -e "${YELLOW}═══ Switching... ═══${NC}"
    echo ""

    local success=0
    local failed=0

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue

        # Add to rollback script before switching
        echo "plesk bin domain -u \"${domain}\" -php_handler_id \"${source_handler}\"" >> "$rollback_file"

        if switch_domain "$domain" "$target_handler" "$source_handler"; then
            ((++success))
        else
            ((++failed))
        fi
    done <<< "$domains"

    echo ""
    echo -e "${YELLOW}═══ Summary ═══${NC}"
    echo ""
    print_success "Switched: ${success}"
    [[ $failed -gt 0 ]] && print_error "Failed: ${failed}"
    echo ""
    print_info "Log file: ${LOG_FILE}"
    print_info "Rollback script: ${rollback_file}"
    echo ""

    log "INFO" "Bulk switch completed - Success: ${success}, Failed: ${failed}"
}

#-------------------------------------------------------------------------------
# Main Menu
#-------------------------------------------------------------------------------

show_menu() {
    echo -e "${YELLOW}═══ Menu ═══${NC}"
    echo ""
    echo "  [1] Show current PHP usage"
    echo "  [2] Show available handlers"
    echo "  [3] Bulk switch PHP version"
    echo "  [4] List domains for a handler"
    echo "  [q] Quit"
    echo ""
    read -rp "  Select option: " option

    case "$option" in
        1)
            echo ""
            show_current_usage
            ;;
        2)
            echo ""
            show_available_handlers
            ;;
        3)
            echo ""
            local source target
            source=$(select_handler "Select SOURCE handler (to migrate FROM):" true)
            echo ""
            print_info "Source: ${source}"
            echo ""
            target=$(select_handler "Select TARGET handler (to migrate TO):" false)
            echo ""
            print_info "Target: ${target}"

            if [[ "$source" == "$target" ]]; then
                print_error "Source and target handlers are the same"
                return
            fi

            perform_bulk_switch "$source" "$target"
            ;;
        4)
            echo ""
            local handler
            handler=$(select_handler "Select handler to list domains:" true)
            echo ""
            echo -e "${YELLOW}═══ Domains using ${handler} ═══${NC}"
            echo ""
            get_domains_by_handler "$handler" | sed 's/^/  • /'
            echo ""
            ;;
        q|Q)
            echo ""
            print_info "Goodbye!"
            log "INFO" "Session ended"
            exit 0
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------

main() {
    check_root
    check_plesk
    init_log

    show_header

    while true; do
        show_menu
    done
}

main "$@"
