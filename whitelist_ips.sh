#!/bin/bash
# Authors: LRob - www.lrob.fr
# Description: Massively whitelist IPs in Plesk's fail2ban. You can use use Google, Bing or other provider's JSON URLs containing all their relevant IP ranges and whitelist them all at once.
# Version: 0.1

# GoogleBot URL (2025): https://developers.google.com/search/apis/ipranges/googlebot.json
# BingBot URL (2025): https://www.bing.com/toolbox/bingbot.json

# Prompt user for JSON URL
read -p "Enter the JSON URL containing IP ranges: " json_url
if [[ -z "${json_url}" ]]; then
    echo "URL cannot be empty. Exiting."
    exit 1
fi

# Check if the URL is reachable
if ! curl --output /dev/null --silent --head --fail "${json_url}"; then
    echo "Invalid or unreachable URL. Exiting."
    exit 1
fi

# Prompt user for description
read -p "Enter a description for the trusted IPs: " description

# Download and parse JSON directly in RAM
ip_ranges=$(curl -s "${json_url}" | jq -r '.prefixes[].ipv4Prefix, .prefixes[].ipv6Prefix' | grep -v null | paste -sd ";" -)

# Add IPs to Plesk's trusted list with description
if [[ -n "${ip_ranges}" ]]; then
    echo "Adding the following IPs to Plesk trusted list: ${ip_ranges}"
    plesk bin ip_ban --add-trusted "${ip_ranges}" -description "${description}"
else
    echo "No valid IP ranges found. Exiting."
fi

echo "All provided IPs have been added to the trusted list with description: ${description}."
