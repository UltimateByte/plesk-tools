#!/usr/bin/env python3
# =============================================================================
# uptime-kuma-sync.py - Sync Plesk domains to Uptime Kuma monitors via Socket.io
# Called by uptime-kuma-sync.sh - do not run directly
# Author: LRob - https://www.lrob.fr/
# License: GNU General Public License v3.0
# =============================================================================

import sys
import json
import time
import argparse
from pathlib import Path

import socketio

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------
sio = socketio.Client()
monitor_list = {}
authenticated = False
config = {}


# -----------------------------------------------------------------------------
# Socket.io Event Handlers
# -----------------------------------------------------------------------------
@sio.event
def connect():
    print("  Connected to Uptime Kuma")


@sio.event
def disconnect():
    print("  Disconnected from Uptime Kuma")


@sio.on("monitorList")
def on_monitor_list(data):
    global monitor_list
    monitor_list = data


# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------
def authenticate():
    global authenticated

    username = config.get("username", "")
    password = config.get("password", "")

    if not username or not password:
        print("ERROR: No username/password configured")
        sys.exit(1)

    max_retries = 3
    for attempt in range(1, max_retries + 1):
        print(f"  Authenticating (attempt {attempt}/{max_retries})...")
        response = call_with_callback("login", {
            "username": username,
            "password": password,
            "token": ""
        }, timeout=30)

        if response and response.get("ok"):
            print("  Login successful")
            authenticated = True
            return True

        if attempt < max_retries:
            print("  Retrying...")
            time.sleep(2)

    msg = response.get("msg", "Unknown error") if response else "No response (timeout)"
    print(f"ERROR: Authentication failed after {max_retries} attempts: {msg}")
    sys.exit(1)


def call_with_callback(event, data, timeout=30):
    try:
        response = sio.call(event, data, timeout=timeout)
        return response
    except socketio.exceptions.TimeoutError:
        print(f"  WARNING: Timeout waiting for {event} response")
        return None
    except Exception as e:
        print(f"  WARNING: Error in {event}: {e}")
        return None


# -----------------------------------------------------------------------------
# Domain File Parsing
# -----------------------------------------------------------------------------
def load_domains():
    domains = {}
    path = Path(config["domains_file"])
    if not path.exists():
        print(f"ERROR: Domains file not found: {config['domains_file']}")
        sys.exit(1)

    for line in path.read_text().strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 3:
            name = parts[0]
            url = parts[2]
            domains[name] = url

    return domains


# -----------------------------------------------------------------------------
# Monitor Operations
# -----------------------------------------------------------------------------
def get_existing_monitors():
    existing = {}
    parent_id = config["parent_group_id"]
    for monitor_id, monitor in monitor_list.items():
        if monitor.get("parent") == parent_id and monitor.get("type") == "http":
            existing[monitor["name"]] = {
                "id": int(monitor_id),
                "url": monitor.get("url", "")
            }
    return existing


def create_monitor(name, url):
    notif_list = {str(nid): True for nid in config["notification_ids"]}

    monitor_data = {
        "name": name,
        "type": "http",
        "url": url,
        "method": "GET",
        "interval": config["monitor_interval"],
        "retryInterval": config["monitor_retry_interval"],
        "timeout": config["monitor_timeout"],
        "maxretries": config["monitor_max_retries"],
        "maxredirects": config["monitor_max_redirects"],
        "resendInterval": 0,
        "active": True,
        "parent": config["parent_group_id"],
        "notificationIDList": notif_list,
        "accepted_statuscodes": ["200-299"],
        "expiryNotification": True,
        "domainExpiryNotification": False,
        "ignoreTls": False,
        "upsideDown": False,
        "packetSize": 56,
        "httpBodyEncoding": "json",
        "conditions": [],
        "kafkaProducerBrokers": [],
        "rabbitmqNodes": [],
        "kafkaProducerSaslOptions": {"mechanism": "None"},
    }

    response = call_with_callback("add", monitor_data)

    if response and response.get("ok"):
        monitor_id = response.get("monitorID", "?")
        print(f"  Created: {name} -> {url} (ID: {monitor_id})")
        return True
    else:
        msg = response.get("msg", "Unknown error") if response else "No response"
        print(f"  ERROR creating {name}: {msg}")
        return False


def delete_monitor(monitor_id, name):
    response = call_with_callback("deleteMonitor", monitor_id)

    if response and response.get("ok"):
        print(f"  Deleted: {name} (ID: {monitor_id})")
        return True
    else:
        msg = response.get("msg", "Unknown error") if response else "No response"
        print(f"  ERROR deleting {name}: {msg}")
        return False


# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
def cmd_sync(dry_run=False):
    label = "Sync preview (dry-run)" if dry_run else "Syncing monitors"
    print(f"=== {label} ===")

    domains = load_domains()
    existing = get_existing_monitors()

    to_create = {name: url for name, url in domains.items() if name not in existing}

    if not to_create:
        print("  Nothing to create, all domains already monitored")
        return

    if dry_run:
        for name, url in sorted(to_create.items()):
            print(f"  Would create: {name} -> {url}")
        print(f"\nTotal: {len(to_create)} monitor(s) to create")
        return

    created = 0
    for name, url in sorted(to_create.items()):
        if create_monitor(name, url):
            created += 1
        time.sleep(0.2)

    print()
    print(f"Created: {created} monitor(s)")
    print(f"Total in file: {len(domains)}")


def cmd_list():
    print(f"=== Monitors in group (parent={config['parent_group_id']}) ===")
    existing = get_existing_monitors()

    for name, data in sorted(existing.items()):
        print(f"  [{data['id']}] {name} - {data['url']}")

    print(f"\nTotal: {len(existing)} monitor(s)")


def cmd_cleanup(confirm=False):
    label = "Removing obsolete monitors" if confirm else "Monitors to be removed (preview)"
    print(f"=== {label} ===")

    domains = load_domains()
    existing = get_existing_monitors()

    to_delete = [(data["id"], name, data["url"]) for name, data in existing.items() if name not in domains]

    if not to_delete:
        print("  Nothing to remove")
        return

    if not confirm:
        for mid, name, url in to_delete:
            print(f"  [{mid}] {name} - {url}")
        print(f"\nTotal to delete: {len(to_delete)} monitor(s)")
        print("Run with --cleanup-confirm to delete these monitors and their data.")
        return

    deleted = 0
    for mid, name, url in to_delete:
        if delete_monitor(mid, name):
            deleted += 1
        time.sleep(0.2)

    print(f"\nDeleted: {deleted} monitor(s)")


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
def main():
    global config

    parser = argparse.ArgumentParser(description="Uptime Kuma sync (called by wrapper)")
    parser.add_argument("--action", required=True, choices=["sync", "list", "cleanup", "cleanup-confirm"])
    parser.add_argument("--config", required=True, help="JSON config string")
    parser.add_argument("--dry-run", action="store_true", help="Preview only")

    args = parser.parse_args()
    config = json.loads(args.config)

    # Connect
    print(f"Connecting to {config['url']}...")
    try:
        sio.connect(config["url"], transports=["websocket"])
    except Exception as e:
        print(f"ERROR: Connection failed: {e}")
        sys.exit(1)

    time.sleep(2)  # Wait for server to be ready

    authenticate()
    print("  Loading monitors...")
    time.sleep(1)

    try:
        if args.action == "sync":
            cmd_sync(dry_run=args.dry_run)
        elif args.action == "list":
            cmd_list()
        elif args.action == "cleanup":
            cmd_cleanup(confirm=False)
        elif args.action == "cleanup-confirm":
            cmd_cleanup(confirm=True)
    finally:
        sio.disconnect()


if __name__ == "__main__":
    main()
