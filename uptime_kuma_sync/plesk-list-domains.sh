#!/bin/bash
# =============================================================================
# plesk-list-domains.sh - List active Plesk domains with www preference detection
# Author: LRob - https://www.lrob.fr/
# License: MIT
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
CURL_TIMEOUT=10
OUTPUT_FORMAT="simple"  # simple, csv, json
OUTPUT_FILE="/root/domains-list"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# Check if domain is active (not suspended)
is_domain_active() {
    local domain="$1"
    local status
    status=$(plesk bin domain -i "$domain" 2>/dev/null | grep -E "^Domain status:" | awk -F: '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ "$status" == "OK" ]]
}

# Detect www preference via curl redirect
# Returns: www, non-www, or redirect
detect_www_preference() {
    local domain="$1"
    local location http_code

    # Test non-www first
    location=$(curl -sI --max-time "$CURL_TIMEOUT" "https://$domain/" 2>/dev/null | grep -i "^location:" | head -1 | awk '{print $2}' | tr -d '\r')

    if [[ "$location" == "https://www.$domain"* ]] || [[ "$location" == "http://www.$domain"* ]]; then
        echo "www"
        return
    fi

    # Test www version
    location=$(curl -sI --max-time "$CURL_TIMEOUT" "https://www.$domain/" 2>/dev/null | grep -i "^location:" | head -1 | awk '{print $2}' | tr -d '\r')

    if [[ "$location" == "https://$domain"* ]] || [[ "$location" == "http://$domain"* ]]; then
        echo "non-www"
        return
    fi

    # No www redirect detected - check which one responds with 200
    http_code=$(curl -sI --max-time "$CURL_TIMEOUT" -o /dev/null -w '%{http_code}' "https://$domain/" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        echo "non-www"
    else
        http_code=$(curl -sI --max-time "$CURL_TIMEOUT" -o /dev/null -w '%{http_code}' "https://www.$domain/" 2>/dev/null || echo "000")
        if [[ "$http_code" =~ ^2 ]]; then
            echo "www"
        else
            echo "redirect"
        fi
    fi
}

# Build the preferred URL
get_preferred_url() {
    local domain="$1"
    local www_pref="$2"

    case "$www_pref" in
        www)     echo "https://www.$domain/" ;;
        non-www) echo "https://$domain/" ;;
        *)       echo "https://$domain/" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

List active Plesk domains with www preference detection.

Options:
    -f, --format FORMAT    Output format: simple (default), csv, json
    -o, --output FILE      Output file (default: $OUTPUT_FILE)
    -t, --timeout SECS     Curl timeout in seconds (default: $CURL_TIMEOUT)
    -h, --help             Show this help

Examples:
    $(basename "$0")
    $(basename "$0") -f csv
    $(basename "$0") -o /tmp/domains.txt
EOF
    exit 0
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--format)  OUTPUT_FORMAT="$2"; shift 2 ;;
        -o|--output)  OUTPUT_FILE="$2"; shift 2 ;;
        -t|--timeout) CURL_TIMEOUT="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

# Get all domains
mapfile -t domains < <(plesk bin domain -l 2>/dev/null)

if [[ ${#domains[@]} -eq 0 ]]; then
    echo "No domains found." >&2
    exit 1
fi

# Write to file
{
    # Output header
    case "$OUTPUT_FORMAT" in
        csv)  echo "domain,www_preference,url" ;;
        json) echo "[" ;;
    esac

    first=true
    for domain in "${domains[@]}"; do
        # Skip if suspended
        if ! is_domain_active "$domain"; then
            continue
        fi

        www_pref=$(detect_www_preference "$domain")
        url=$(get_preferred_url "$domain" "$www_pref")

        case "$OUTPUT_FORMAT" in
            simple)
                echo "$domain $www_pref $url"
                ;;
            csv)
                echo "$domain,$www_pref,$url"
                ;;
            json)
                if $first; then
                    first=false
                else
                    echo ","
                fi
                printf '  {"domain": "%s", "www_preference": "%s", "url": "%s"}' "$domain" "$www_pref" "$url"
                ;;
        esac
    done

    # Close JSON array
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        echo ""
        echo "]"
    fi
} > "$OUTPUT_FILE"

echo "Output written to $OUTPUT_FILE"
