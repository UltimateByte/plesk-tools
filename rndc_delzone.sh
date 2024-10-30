#!/bin/bash
# Authors: LRob - www.lrob.fr
# Description: Uses SSH to delzone a domain using rndc on multiple servers (slave DNS). Useful when Plesk doesn't remove them for any reason.
# Requires: Root Access via SSH key, does not require Plesk, works on any DNS server
# Version: 0.2

# Define the name servers and domain
name_servers=("ns1.example.net" "ns2.example.net" "ns3.example.net")
#name_servers=("ns1.lrob.net" "ns2.lrob.net" "ns3.lrob.net")
domain="${1}"  # Accept the domain as an argument when running the script

# Check if a domain was provided
if [ -z "${domain}" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Loop through each name server and execute the rndc command
for ns in "${name_servers[@]}"; do
    # Run the rndc command on the remote name server
    echo "[ ${ns} ]"
    ssh "root@${ns}" "rndc delzone -clean ${domain}"
done
