#!/opt/uptime-kuma-sync/venv/bin/python
# =============================================================================
# uptime-kuma-sync.py - Sync Plesk domains to Uptime Kuma monitors via Socket.io
# Author: LRob - https://www.lrob.fr/
# License: MIT
# =============================================================================

import sys
import json
import time
import argparse
from pathlib import Path

import socketio

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
UPTIME_KUMA_URL = "https://your-uptime-kuma-instance.com"
USERNAME = ""
PASSWORD = ""
JWT_FILE = "/opt/uptime-kuma-sync/jwt_token"

DOMAINS_FILE = "/root/uptime-kuma-domains-list"
PARENT_GROUP_ID = 1

# Monitor settings
MONITOR_INTERVAL = 60
MONITOR_RETRY_INTERVAL = 60
MONITOR_TIMEOUT = 30
MONITOR_MAX_RETRIES = 1
MONITOR_MAX_REDIRECTS = 10

# Default notification IDs to attach (empty = none, or list like [1, 2])
DEFAULT_NOTIFICATION_IDS = [1]

# -----------------------------------------------------------------------------
# Globals
# -----------------------------------------------------------------------------
sio = socketio.Client()
monitor_list = {}
authenticated = False
jwt_token = None


# -----------------------------------------------------------------------------
# JWT Management
# -----------------------------------------------------------------------------
def load_jwt():
    """Load JWT from file if exists."""
    path = Path(JWT_FILE)
    if path.exists():
        return path.read_text().strip()
    return None


def save_jwt(token):
    """Save JWT to file."""
    Path(JWT_FILE).write_text(token)
    print(f"  JWT saved to {JWT_FILE}")


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
    """Authenticate via JWT or username/password."""
    global authenticated, jwt_token

    # Try JWT first
    jwt_token = load_jwt()
    if jwt_token:
        print("  Attempting JWT authentication...")
        response = call_with_callback("loginByToken", jwt_token)
        if response and response.get("ok"):
            print("  JWT authentication successful")
            authenticated = True
            return True
        else:
            print("  JWT expired or invalid, falling back to password")

    # Fallback to username/password
    if not USERNAME or not PASSWORD:
        print("ERROR: No valid JWT and no username/password configured")
        sys.exit(1)

    print("  Authenticating with username/password...")
    response = call_with_callback("login", {
        "username": USERNAME,
        "password": PASSWORD,
        "token": ""  # 2FA token if needed
    })

    if response and response.get("ok"):
        print("  Login successful")
        authenticated = True
        if response.get("token"):
            save_jwt(response["token"])
            jwt_token = response["token"]
        return True
    else:
        msg = response.get("msg", "Unknown error") if response else "No response"
        print(f"ERROR: Authentication failed: {msg}")
        sys.exit(1)


def call_with_callback(event, data, timeout=30):
    """Emit an event and wait for callback response."""
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
    """Load domains from file. Returns dict {name: url}."""
    domains = {}
    path = Path(DOMAINS_FILE)
    if not path.exists():
        print(f"ERROR: Domains file not found: {DOMAINS_FILE}")
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
    """Get monitors under the parent group."""
    existing = {}
    for monitor_id, monitor in monitor_list.items():
        if monitor.get("parent") == PARENT_GROUP_ID and monitor.get("type") == "http":
            existing[monitor["name"]] = {
                "id": int(monitor_id),
                "url": monitor.get("url", "")
            }
    return existing


def create_monitor(name, url):
    """Create a new HTTP monitor."""
    # Build notification ID list
    notif_list = {str(nid): True for nid in DEFAULT_NOTIFICATION_IDS}

    monitor_data = {
        "name": name,
        "type": "http",
        "url": url,
        "method": "GET",
        "interval": MONITOR_INTERVAL,
        "retryInterval": MONITOR_RETRY_INTERVAL,
        "timeout": MONITOR_TIMEOUT,
        "maxretries": MONITOR_MAX_RETRIES,
        "maxredirects": MONITOR_MAX_REDIRECTS,
        "resendInterval": 0,
        "active": True,
        "parent": PARENT_GROUP_ID,
        "notificationIDList": notif_list,
        "accepted_statuscodes": ["200-299"],
        "expiryNotification": True,
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
    """Delete a monitor."""
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
def cmd_sync():
    """Sync monitors: create missing ones."""
    print("=== Syncing monitors ===")

    domains = load_domains()
    existing = get_existing_monitors()

    created = 0
    for name, url in domains.items():
        if name not in existing:
            if create_monitor(name, url):
                created += 1
            time.sleep(0.2)  # Small delay to avoid overwhelming

    print()
    print(f"Created: {created} monitor(s)")
    print(f"Total in file: {len(domains)}")


def cmd_list():
    """List monitors in the parent group."""
    print(f"=== Monitors in group (parent={PARENT_GROUP_ID}) ===")

    existing = get_existing_monitors()

    for name, data in sorted(existing.items()):
        print(f"  [{data['id']}] {name} - {data['url']}")

    print()
    print(f"Total: {len(existing)} monitor(s)")


def cmd_cleanup_preview():
    """Preview monitors to be deleted."""
    print("=== Monitors to be removed (preview) ===")

    domains = load_domains()
    existing = get_existing_monitors()

    to_delete = []
    for name, data in existing.items():
        if name not in domains:
            to_delete.append((data["id"], name, data["url"]))
            print(f"  [{data['id']}] {name} - {data['url']}")

    print()
    print(f"Total to delete: {len(to_delete)} monitor(s)")
    print("Run with --cleanup-confirm to delete these monitors and their data.")


def cmd_cleanup_confirm():
    """Delete obsolete monitors."""
    print("=== Removing obsolete monitors ===")

    domains = load_domains()
    existing = get_existing_monitors()

    deleted = 0
    for name, data in existing.items():
        if name not in domains:
            if delete_monitor(data["id"], name):
                deleted += 1
            time.sleep(0.2)

    print()
    print(f"Deleted: {deleted} monitor(s)")


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Sync Plesk domains to Uptime Kuma monitors"
    )
    parser.add_argument("-s", "--sync", action="store_true",
                        help="Sync monitors (create missing ones)")
    parser.add_argument("-l", "--list", action="store_true",
                        help="List current monitors in group")
    parser.add_argument("-c", "--cleanup", action="store_true",
                        help="Preview monitors to be removed")
    parser.add_argument("-C", "--cleanup-confirm", action="store_true",
                        help="Remove obsolete monitors (with data)")

    args = parser.parse_args()

    if not any([args.sync, args.list, args.cleanup, args.cleanup_confirm]):
        parser.print_help()
        sys.exit(0)

    # Connect
    print(f"Connecting to {UPTIME_KUMA_URL}...")
    try:
        sio.connect(UPTIME_KUMA_URL, transports=["websocket"])
    except Exception as e:
        print(f"ERROR: Connection failed: {e}")
        sys.exit(1)

    # Authenticate
    authenticate()

    # Wait for monitor list
    time.sleep(1)

    try:
        if args.sync:
            cmd_sync()
        elif args.list:
            cmd_list()
        elif args.cleanup:
            cmd_cleanup_preview()
        elif args.cleanup_confirm:
            cmd_cleanup_confirm()
    finally:
        sio.disconnect()


if __name__ == "__main__":
    main()
