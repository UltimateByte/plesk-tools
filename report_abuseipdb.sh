#!/bin/bash
# Authors: Original script from brother4 (Plesk community forum) ; heavily reworked by LRob - www.lrob.fr
# Description: Reports IPs banned by fail2ban on a Plesk server to AbuseIPDB
# Requires: Plesk server, and AbuseIPDB API key
# Version: 0.2

# Your AbuseIPDB API key
api_key=""

# File where already reported ips are stored
reported_ips_file="/var/log/reported_ips.log"

# Categories documentation
# Source : https://www.abuseipdb.com/categories
# ID  Title                Description
#  1  DNS Compromise       Altering DNS records resulting in improper redirection.
#  2  DNS Poisoning        Falsifying domain server cache (cache poisoning).
#  3  Fraud Orders         Fraudulent orders.
#  4  DDoS Attack          Participating in distributed denial-of-service (usually part of a botnet).
#  5  FTP Brute-Force      Brute-force attempts to access an FTP service.
#  6  Ping of Death        Oversized IP packet.
#  7  Phishing             Phishing websites and/or email.
#  8  Fraud VoIP           VoIP fraud.
#  9  Open Proxy           Open proxy, open relay, or Tor exit node.
# 10  Web Spam             Comment/forum spam, HTTP referer spam, or other CMS spam.
# 11  Email Spam           Spam email content, infected attachments, and phishing emails. Note: Limit comments to only relevant information (instead of log dumps) and be sure to remove PII if you want to remain anonymous.
# 12  Blog Spam            CMS blog comment spam.
# 13  VPN IP               VPN-related IP activity.
# 14  Port Scan            Scanning for open ports and vulnerable services.
# 15  Hacking              Hacking attempts.
# 16  SQL Injection        Attempts at SQL injection.
# 17  Spoofing             Email sender spoofing.
# 18  Brute-Force          Credential brute-force attacks on webpage logins and services like SSH, FTP, SIP, SMTP, RDP, etc. This category is separate from DDoS attacks.
# 19  Bad Web Bot          Webpage scraping (for email addresses, content, etc) and crawlers that do not honor robots.txt. Excessive requests and user agent spoofing can also be reported here.
# 20  Exploited Host       Host is likely infected with malware and being used for other attacks or to host malicious content. The host owner may not be aware of the compromise. This category is often used in combination with other attack categories.
# 21  Web App Attack       Attempts to probe for or exploit installed web applications such as a CMS like WordPress/Drupal, e-commerce solutions, forum software, phpMyAdmin and various other software plugins/solutions.
# 22  SSH                  Secure Shell (SSH) abuse. Use this category in combination with more specific categories.
# 23  IoT Targeted         Abuse was targeted at an "Internet of Things" type device. Include information about what type of device was targeted in the comments.

# If the file doesn't exist, create it
[ ! -f "${reported_ips_file}" ] && touch "${reported_ips_file}"

# Declare jails, categories, and comments in a single array
# You may edit according to your own jails
declare -A jail_info
jail_info=(
  ["plesk-apache"]="21|Apache web server attack detected by Fail2Ban in plesk-apache jail"
  ["plesk-apache-badbot"]="19|Bad web bot activity detected by Fail2Ban in plesk-apache-badbot jail"
  ["plesk-dovecot"]="18|POP or IMAP failed login attempts detected by Fail2Ban in plesk-dovecot jail"
  ["plesk-modsecurity"]="21|WAF repeated trigger detected by Fail2Ban in plesk-modsecurity jail"
  ["plesk-panel"]="21|Plesk panel brute-force detected by Fail2Ban in plesk-panel jail"
  ["plesk-postfix"]="11,18|SMTP brute-force detected by Fail2Ban in plesk-postfix jail"
  ["plesk-proftpd"]="5|FTP brute-force attack detected by Fail2Ban in plesk-proftpd jail"
  ["plesk-roundcube"]="11,18|Roundcube brute-force detected by Fail2Ban in plesk-roundcube jail"
  ["plesk-wordpress"]="18,21|WordPress login brute-force detected by Fail2Ban in plesk-wordpress jail"
  ["recidive"]="15|Repeated attacks detected by Fail2Ban in recidive jail"
  ["ssh"]="18,22|SSH abuse or brute-force attack detected by Fail2Ban in ssh jail"
)

# Iterate over all jails
for jail in "${!jail_info[@]}"; do
  # Get categories and comment from the jail_info array
  categories=$(echo "${jail_info[${jail}]}" | cut -d'|' -f1)
  comment=$(echo "${jail_info[${jail}]}" | cut -d'|' -f2)

  # Get banned ips for the current jail
  banned_ips=$(fail2ban-client status "${jail}" | awk -F "Banned IP list:" '{print $2}' | xargs)

  # If "banned_ips" does not contain "ERROR", then the jail exists and is active, continue
  if [[ "${banned_ips}" != *"ERROR"* ]]; then
    # Iterate over all banned ips
    for ip in ${banned_ips}; do
      # Check if the ip was already reported
      if ! grep -q "^${ip}$" "${reported_ips_file}"; then
        # Report the IP to AbuseIPDB with categories and comment
        response=$(curl -sS -X POST https://api.abuseipdb.com/api/v2/report \
          -H "Key: ${api_key}" \
          -H "Accept: application/json" \
          -d "ip=${ip}&categories=${categories}&comment=${comment}")
  
        # Optionally check if there's an error in the response
        if echo "${response}" | grep -qi "error"; then
            echo "Error reporting IP ${ip}: ${response}"
        fi
  
        # Add the IP to the list of reported IPs
        echo "${ip}" >> "${reported_ips_file}"
      fi
    done
  fi
done
