#!/bin/bash
# Authors: LRob - www.lrob.fr
# Description: Massively whitelist IPs for CloudFlare, Googlebot, Bingbot in Plesk's fail2ban. You can add services to predefined ones if needed.
# Version: 0.2

# Predefined services
declare -A SERVICES=(
    ["cloudflare"]="https://api.cloudflare.com/client/v4/ips|Cloudflare IPs|cloudflare"
    ["google"]="https://developers.google.com/static/search/apis/ipranges/googlebot.json|Googlebot IPs|standard"
    ["bing"]="https://www.bing.com/toolbox/bingbot.json|Bingbot IPs|standard"
)

parse_ips() {
    local json="$1"
    local format="$2"
    
    if [[ "$format" == "cloudflare" ]]; then
        echo "$json" | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]' 2>/dev/null | grep -v null | paste -sd ";" -
    else
        # Standard format (Google/Bing)
        echo "$json" | jq -r '.prefixes[].ipv4Prefix, .prefixes[].ipv6Prefix' 2>/dev/null | grep -v null | paste -sd ";" -
    fi
}

whitelist_service() {
    local url="$1"
    local description="$2"
    local format="$3"
    
    echo "Fetching IPs for: ${description}..."
    
    if ! curl --silent --fail --max-time 15 "${url}" > /dev/null; then
        echo "Error: Cannot reach ${url}"
        return 1
    fi
    
    local json
    json=$(curl -s "${url}")
    
    local ip_ranges
    ip_ranges=$(parse_ips "$json" "$format")
    
    if [[ -n "${ip_ranges}" ]]; then
        echo "Adding IPs to Plesk trusted list..."
        plesk bin ip_ban --add-trusted "${ip_ranges}" -description "${description}"
        echo "Done: ${description}"
    else
        echo "No valid IP ranges found for ${description}"
        return 1
    fi
}

show_menu() {
    echo "====================================="
    echo "  Plesk IP Whitelist Tool"
    echo "====================================="
    echo "1) Cloudflare"
    echo "2) Googlebot"
    echo "3) Bingbot"
    echo "4) All of the above"
    echo "5) Custom JSON URL"
    echo "6) Exit"
    echo "====================================="
}

custom_url() {
    read -p "Enter the JSON URL: " json_url
    [[ -z "${json_url}" ]] && { echo "URL cannot be empty."; return 1; }
    
    read -p "Enter description: " description
    [[ -z "${description}" ]] && description="Custom IPs"
    
    echo "Select JSON format:"
    echo "1) Standard (.prefixes[].ipv4Prefix/ipv6Prefix) - Google/Bing style"
    echo "2) Cloudflare (.result.ipv4_cidrs/ipv6_cidrs)"
    read -p "Choice [1-2]: " fmt_choice
    
    local format="standard"
    [[ "$fmt_choice" == "2" ]] && format="cloudflare"
    
    whitelist_service "$json_url" "$description" "$format"
}

main() {
    while true; do
        show_menu
        read -p "Select option [1-6]: " choice
        echo
        
        case $choice in
            1)
                IFS='|' read -r url desc fmt <<< "${SERVICES[cloudflare]}"
                whitelist_service "$url" "$desc" "$fmt"
                ;;
            2)
                IFS='|' read -r url desc fmt <<< "${SERVICES[google]}"
                whitelist_service "$url" "$desc" "$fmt"
                ;;
            3)
                IFS='|' read -r url desc fmt <<< "${SERVICES[bing]}"
                whitelist_service "$url" "$desc" "$fmt"
                ;;
            4)
                for key in cloudflare google bing; do
                    IFS='|' read -r url desc fmt <<< "${SERVICES[$key]}"
                    whitelist_service "$url" "$desc" "$fmt"
                    echo
                done
                ;;
            5)
                custom_url
                ;;
            6)
                echo "Bye."
                exit 0
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
        echo
    done
}

main
