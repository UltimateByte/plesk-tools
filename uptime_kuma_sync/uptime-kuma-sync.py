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


notification_list = {}


@sio.on("notificationList")
def on_notification_list(data):
    global notification_list
    notification_list = data


# -----------------------------------------------------------------------------
# Authentication
# -----------------------------------------------------------------------------
_login_response = None
_login_event = None


def authenticate():
    global authenticated, _login_response, _login_event

    import threading
    _login_event = threading.Event()

    username = config.get("username", "")
    password = config.get("password", "")

    if not username or not password:
        print("ERROR: No username/password configured")
        sys.exit(1)

    max_retries = 3
    for attempt in range(1, max_retries + 1):
        print(f"  Authenticating (attempt {attempt}/{max_retries})...")
        _login_response = None
        _login_event.clear()

        def on_login_response(data):
            global _login_response
            _login_response = data
            _login_event.set()

        sio.emit("login", {
            "username": username,
            "password": password,
            "token": ""
        }, callback=on_login_response)

        _login_event.wait(timeout=config.get("login_timeout", 15))

        if _login_response and _login_response.get("ok"):
            print("  Login successful")
            authenticated = True
            return True

        if attempt < max_retries:
            print("  Login failed, reconnecting...")
            try:
                sio.disconnect()
                time.sleep(1)
                sio.connect(config["url"], transports=["websocket"])
                time.sleep(2)
            except Exception as e:
                print(f"  WARNING: Reconnect error: {e}")
                time.sleep(2)

    msg = _login_response.get("msg", "Unknown error") if _login_response else "No response (timeout)"
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
    """Parse the (tab-separated) Plesk domains list.

    Columns: name, seoRedirect, url, reseller, status.
    Returns {name: {"url", "reseller", "status"}} where reseller is "" for
    admin/direct-customer domains and status is the Plesk domain status int
    (0=active, 16/32=suspended). The file is regenerated every run, so it is
    always in the current format.
    """
    domains = {}
    path = Path(config["domains_file"])
    if not path.exists():
        print(f"ERROR: Domains file not found: {config['domains_file']}")
        sys.exit(1)

    for line in path.read_text().strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            name = parts[0]
            url = parts[2]
            reseller = parts[3] if len(parts) >= 4 else ""
            try:
                status = int(parts[4]) if len(parts) >= 5 else 0
            except ValueError:
                status = 0
            domains[name] = {"url": url, "reseller": reseller, "status": status}

    return domains


SUSPENDED_STATUSES = (16, 32)


def name_suffix():
    return config.get("offserver_name_suffix", "") or ""


def strip_suffix(name):
    suffix = name_suffix()
    if suffix and name.endswith(suffix):
        return name[:-len(suffix)]
    return name


# -----------------------------------------------------------------------------
# Off-server detection (DNS)
# -----------------------------------------------------------------------------
def resolve_states(names):
    """Classify each domain against the server's local IPs.

    Returns {name: "on"|"off"|"unknown"}:
      on      - resolves to at least one local interface IP
      off     - resolves, but to none of our IPs (points elsewhere)
      unknown - no resolution / lookup error -> never acted upon

    Resolution goes through the configured public resolver (DNS_RESOLVER) so a
    Plesk box that is itself the DNS master for the zone does not just answer
    with its own local IP. Done in parallel for speed on large fleets.
    """
    import concurrent.futures
    import ipaddress

    try:
        import dns.resolver
        import dns.exception
    except ImportError:
        print("  WARNING: dnspython not installed, skipping off-server detection")
        print("  Run: uptime-kuma-sync --update")
        return {name: "unknown" for name in names}

    def norm(ip):
        # Normalise to a canonical form so IPv6 textual differences
        # (compression, case) don't cause false mismatches.
        try:
            return str(ipaddress.ip_address(ip))
        except ValueError:
            return ip

    local_ips = {norm(ip) for ip in config.get("local_ips", [])}
    resolver_ip = config.get("dns_resolver", "1.1.1.1")

    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [resolver_ip]
    resolver.lifetime = 5.0
    resolver.timeout = 3.0

    def classify(name):
        ips = set()
        for rdtype in ("A", "AAAA"):
            try:
                answer = resolver.resolve(name, rdtype)
                ips.update(norm(r.address) for r in answer)
            except (dns.resolver.NoAnswer, dns.resolver.NXDOMAIN):
                continue
            except dns.exception.DNSException:
                # timeout / SERVFAIL / no nameservers reachable -> inconclusive
                return name, "unknown"
        if not ips:
            return name, "unknown"
        return name, ("on" if ips & local_ips else "off")

    states = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        for name, state in pool.map(classify, names):
            states[name] = state
    return states


# -----------------------------------------------------------------------------
# Monitor Operations
# -----------------------------------------------------------------------------
def find_group_by_name(name):
    """Return [ids] of group monitors with the given name."""
    return [int(mid) for mid, m in monitor_list.items()
            if m.get("type") == "group" and m.get("name") == name]


def resolve_offserver_group(create=False, dry_run=False):
    """Return the off-server group ID, or None.

    Priority: an explicit numeric OFFSERVER_GROUP_ID override, otherwise look up
    OFFSERVER_GROUP_NAME (creating it when create=True and it does not exist).
    """
    override = config.get("offserver_group_id")
    if override not in (None, "", 0):
        return int(override)

    name = config.get("offserver_group_name") or "Off-server"
    found = find_group_by_name(name)
    if found:
        if len(found) > 1:
            print(f"  WARNING: multiple groups named '{name}', using ID {found[0]}")
        return found[0]

    if not create:
        return None
    if dry_run:
        print(f"  Would create off-server group '{name}'")
        return None

    parent = config.get("offserver_group_parent")
    parent = int(parent) if parent not in (None, "", 0) else None
    gid = create_group(name, parent)
    return gid


_reseller_group_cache = {}


def reseller_group_id(reseller, create=False, dry_run=False):
    """Resolve (and optionally create) the Kuma group for a reseller login.

    Group name = RESELLER_GROUP_PREFIX + reseller login. Cached per run.
    """
    if reseller in _reseller_group_cache:
        return _reseller_group_cache[reseller]

    name = (config.get("reseller_group_prefix") or "") + reseller
    found = find_group_by_name(name)
    gid = None
    if found:
        if len(found) > 1:
            print(f"  WARNING: multiple groups named '{name}', using ID {found[0]}")
        gid = found[0]
    elif create:
        if dry_run:
            print(f"  Would create reseller group '{name}'")
        else:
            parent = config.get("reseller_group_parent")
            parent = int(parent) if parent not in (None, "", 0) else None
            gid = create_group(name, parent)

    if gid is not None:
        _reseller_group_cache[reseller] = gid
    return gid


def home_group_id(info, create=False, dry_run=False):
    """The group a domain's monitor belongs to, per GROUPING_MODE.

    by-reseller: reseller-owned -> the reseller's group; admin/direct -> main.
    flat (or unresolved reseller group): the main parent group.
    """
    main_gid = config["parent_group_id"]
    if config.get("grouping_mode", "by-reseller") != "by-reseller":
        return main_gid
    reseller = info.get("reseller") or ""
    if not reseller:
        return main_gid
    gid = reseller_group_id(reseller, create=create, dry_run=dry_run)
    return gid if gid is not None else main_gid


def all_http_monitors():
    """All HTTP monitors keyed by their suffix-stripped name (across all groups).

    Used to match domains to monitors regardless of which group they sit in, so
    grouping moves and the off-server name suffix never produce duplicates.
    """
    out = {}
    for monitor_id, monitor in monitor_list.items():
        if monitor.get("type") != "http":
            continue
        raw = monitor["name"]
        out[strip_suffix(raw)] = {
            "id": int(monitor_id),
            "url": monitor.get("url", ""),
            "parent": monitor.get("parent"),
            "active": monitor.get("active", True),
            "name_raw": raw,
            "bean": monitor,
        }
    return out


def create_group(name, parent=None):
    group_data = {
        "name": name,
        "type": "group",
        "interval": 60,
        "retryInterval": 60,
        "maxretries": 0,
        "resendInterval": 0,
        "active": True,
        "parent": parent,
        "notificationIDList": {},
        "accepted_statuscodes": ["200-299"],
        "conditions": [],
        "kafkaProducerBrokers": [],
        "rabbitmqNodes": [],
        "kafkaProducerSaslOptions": {"mechanism": "None"},
    }
    response = call_with_callback("add", group_data)
    if response and response.get("ok"):
        gid = int(response.get("monitorID"))
        print(f"  Created group '{name}' (ID: {gid})")
        return gid
    msg = response.get("msg", "Unknown error") if response else "No response"
    print(f"  ERROR creating group '{name}': {msg}")
    return None


def edit_monitor(bean, **changes):
    """Apply field changes to an existing monitor via editMonitor.

    Sends the full existing bean (so unrelated settings are preserved) with the
    given fields overridden. Returns True on success.
    """
    payload = dict(bean)
    payload.update(changes)
    response = call_with_callback("editMonitor", payload)
    if response and response.get("ok"):
        return True
    msg = response.get("msg", "Unknown error") if response else "No response"
    print(f"  ERROR editing {bean.get('name', '?')}: {msg}")
    return False


def create_monitor(name, url, parent_gid=None):
    notif_list = {str(nid): True for nid in config["notification_ids"]}
    if parent_gid is None:
        parent_gid = config["parent_group_id"]

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
        "parent": parent_gid,
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


def pause_monitor(monitor_id):
    response = call_with_callback("pauseMonitor", monitor_id)
    return bool(response and response.get("ok"))


def resume_monitor(monitor_id):
    response = call_with_callback("resumeMonitor", monitor_id)
    return bool(response and response.get("ok"))


# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
def cmd_sync(dry_run=False):
    label = "Sync preview (dry-run)" if dry_run else "Syncing monitors"
    print(f"=== {label} ===")

    domains = load_domains()
    # Match across every group (suffix-stripped) so nothing is recreated.
    existing = all_http_monitors()
    suspended_action = config.get("suspended_action", "keep")

    # Don't create monitors for suspended domains when they aren't monitored.
    to_create = {
        name: info for name, info in domains.items()
        if name not in existing
        and not (info["status"] in SUSPENDED_STATUSES and suspended_action == "delete")
    }

    if not to_create:
        print("  Nothing to create, all domains already monitored")
        return

    if dry_run:
        for name, info in sorted(to_create.items()):
            gid = home_group_id(info, create=False)
            where = f"group {gid}" if gid != config["parent_group_id"] else "main group"
            print(f"  Would create: {name} -> {info['url']} ({where})")
        print(f"\nTotal: {len(to_create)} monitor(s) to create")
        return

    created = 0
    for name, info in sorted(to_create.items()):
        gid = home_group_id(info, create=True)
        if create_monitor(name, info["url"], gid):
            created += 1
        time.sleep(0.2)

    print()
    print(f"Created: {created} monitor(s)")
    print(f"Total in file: {len(domains)}")


def cmd_list():
    print("=== HTTP monitors ===")
    existing = all_http_monitors()

    # Map group IDs to names for readable output
    group_names = {int(mid): m.get("name", "?") for mid, m in monitor_list.items()
                   if m.get("type") == "group"}

    for name, data in sorted(existing.items()):
        parent = data["parent"]
        grp = group_names.get(parent, f"#{parent}") if parent else "(root)"
        flag = "" if data["active"] else " [paused]"
        print(f"  [{data['id']}] {data['name_raw']} - {data['url']}  <{grp}>{flag}")

    print(f"\nTotal: {len(existing)} monitor(s)")


def cmd_cleanup(dry_run=False):
    label = "Cleanup preview (dry-run)" if dry_run else "Cleanup"
    print(f"=== {label} ===")

    domains = load_domains()
    main_gid = config["parent_group_id"]
    existing = all_http_monitors()

    # Groups we manage: main + off-server + every reseller group in use.
    managed = {main_gid}
    off_gid = resolve_offserver_group(create=False)
    if off_gid is not None:
        managed.add(off_gid)
    for reseller in {info["reseller"] for info in domains.values() if info["reseller"]}:
        gid = reseller_group_id(reseller, create=False)
        if gid is not None:
            managed.add(gid)

    # --- 1) Obsolete: managed monitor whose domain is gone from Plesk -> delete ---
    obsolete = [(m["id"], key, m["url"]) for key, m in existing.items()
                if key not in domains and m["parent"] in managed]
    if obsolete:
        for mid, key, url in obsolete:
            if dry_run:
                print(f"  Would delete (obsolete): [{mid}] {key} - {url}")
            elif delete_monitor(mid, key):
                time.sleep(0.2)
    else:
        print("  No obsolete monitors")

    # --- 2) Resolve off-server DNS state for domains still in Plesk ---
    offserver_action = config.get("offserver_action", "report")
    present = [n for n in domains if n in existing]
    if offserver_action != "off":
        print(f"\n=== Reconciling {len(present)} monitor(s) (off-server action: {offserver_action}) ===")
        states = resolve_states(present)
    else:
        states = {n: "unknown" for n in present}

    # --- 3) Reconcile each monitor to its desired group / paused / name state ---
    changed = 0
    for name in sorted(present):
        if reconcile_monitor(name, domains[name], existing[name],
                             states.get(name, "unknown"), off_gid, dry_run):
            changed += 1
            if not dry_run:
                time.sleep(0.2)

    if not dry_run:
        print(f"\nReconciled: {changed} monitor(s)")


def reconcile_monitor(name, info, mon, dns_state, off_gid, dry_run):
    """Bring one monitor to its desired state (group, paused, name suffix).

    Desired state is recomputed from scratch each run, so the off-server (move/
    pause) and suspended (pause) actions are inherently reversible: once a domain
    is active and points home again, the monitor is moved back, resumed and
    un-suffixed. Returns True if any change was made (or would be, in dry-run).
    """
    status = info["status"]
    suspended_action = config.get("suspended_action", "keep")
    offserver_action = config.get("offserver_action", "report")

    delete = False
    paused = False
    suffixed = False
    group = home_group_id(info, create=not dry_run, dry_run=dry_run)
    reason = []

    # Suspended-in-Plesk policy
    if status in SUSPENDED_STATUSES:
        if suspended_action == "delete":
            delete = True
            reason.append("suspended")
        elif suspended_action == "pause":
            paused = True
            reason.append("suspended")

    # Off-server policy (DNS no longer points here)
    if dns_state == "off" and offserver_action != "off":
        if offserver_action == "delete":
            delete = True
            reason.append("off-server")
        elif offserver_action == "pause":
            paused = True
            suffixed = True
            reason.append("off-server")
        elif offserver_action == "move":
            tgid = resolve_offserver_group(create=not dry_run, dry_run=dry_run)
            if tgid is not None:
                group = tgid
            paused = True
            suffixed = True
            reason.append("off-server")
        elif offserver_action == "report":
            print(f"  off-server (report only): {name}")

    # Compute the operations needed to reach the desired state
    ops = []
    edits = {}
    if delete:
        ops.append("delete")
    else:
        if group is not None and mon["parent"] != group:
            edits["parent"] = group
            ops.append("move group")
        desired_name = name + (name_suffix() if suffixed else "")
        if mon["name_raw"] != desired_name:
            edits["name"] = desired_name
            ops.append("rename")
        if paused and mon["active"]:
            ops.append("pause")
        elif not paused and not mon["active"]:
            ops.append("resume")

    if not ops:
        return False

    tag = f" ({'/'.join(reason)})" if reason else ""
    if dry_run:
        print(f"  Would {', '.join(ops)}: {name}{tag}")
        return True

    if delete:
        return delete_monitor(mon["id"], name)

    ok = True
    if edits:
        ok = edit_monitor(mon["bean"], **edits)
    if ok and "pause" in ops:
        pause_monitor(mon["id"])
    if ok and "resume" in ops:
        resume_monitor(mon["id"])
    if ok:
        print(f"  {name}{tag}: {', '.join(ops)}")
    return ok


def cmd_info():
    """List available groups and notifications to help with setup."""
    # Groups (monitors of type "group")
    print("=== Available monitor groups ===")
    groups_found = False
    for monitor_id, monitor in monitor_list.items():
        if monitor.get("type") == "group":
            print(f"  ID: {int(monitor_id):3d}  Name: {monitor['name']}")
            groups_found = True
    if not groups_found:
        print("  No groups found. Create a group in Uptime Kuma first.")

    # Notifications
    print("\n=== Available notifications ===")
    if notification_list:
        for notif in notification_list:
            if isinstance(notif, dict):
                print(f"  ID: {notif.get('id', '?'):3d}  Name: {notif.get('name', 'unnamed')}  Type: {notif.get('type', '?')}")
    else:
        print("  No notifications found. Create a notification in Uptime Kuma first.")


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
def main():
    global config

    parser = argparse.ArgumentParser(description="Uptime Kuma sync (called by wrapper)")
    parser.add_argument("--action", required=True, choices=["sync", "list", "cleanup", "info"])
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
        if args.action == "info":
            cmd_info()
        elif args.action == "sync":
            cmd_sync(dry_run=args.dry_run)
        elif args.action == "list":
            cmd_list()
        elif args.action == "cleanup":
            cmd_cleanup(dry_run=args.dry_run)
    finally:
        sio.disconnect()


if __name__ == "__main__":
    main()
