# Uptime Kuma Sync

Automatically sync active domains from a Plesk server to HTTP monitors in [Uptime Kuma](https://github.com/louislam/uptime-kuma).

A single bash script handles everything: installation, updates, Plesk domain listing, sync, cleanup, and cron scheduling.

## Features

- Instant domain listing via Plesk database (no HTTP requests)
- Automatic www / non-www preference detection from Plesk SEO redirect settings
- Creates missing monitors in Uptime Kuma via Socket.io
- Removes obsolete monitors (domains removed from Plesk)
- Grouping by reseller: one Kuma group per Plesk reseller, admin/direct domains in the main group
- Off-server detection: flags domains whose DNS no longer points to this server, with configurable action (report / pause / move / delete)
- Suspended-domain handling (keep / pause / delete), reversible on reactivation
- Configurable domain exclusion patterns (`.plesk.page` excluded by default)
- Dry-run mode to preview changes before applying
- Auto-install on first run if dependencies are missing
- Self-update from GitHub while preserving configuration
- Logging with automatic rotation (30 days by default)
- One-command cron setup
- Domain expiry notifications disabled by default (avoids the Kuma 2.x notification spam)

## Requirements

- Plesk server
- Python 3 with `python3-venv`
- Uptime Kuma ≥ 2.0
- Root access

## Installation

```bash
mkdir -p /opt/uptime-kuma-sync
curl -fsSL https://raw.githubusercontent.com/UltimateByte/plesk-tools/main/uptime_kuma_sync/uptime-kuma-sync.sh -o /opt/uptime-kuma-sync/uptime-kuma-sync.sh
chmod +x /opt/uptime-kuma-sync/uptime-kuma-sync.sh
/opt/uptime-kuma-sync/uptime-kuma-sync.sh --install
```

The installer will prompt for your Uptime Kuma URL and credentials, then connect to list available monitor groups and notifications so you can pick the right IDs. These are saved to `/opt/uptime-kuma-sync/.env` and can be edited later.

Additional settings (monitoring intervals, exclusion patterns, cron schedule) can be adjusted in the `.env` file:

```bash
nano /opt/uptime-kuma-sync/.env
```

Then run:

```bash
uptime-kuma-sync --sync --dry-run
```

## Usage

```
uptime-kuma-sync [OPTION]
```

| Option | Description |
|---|---|
| `--install` | Set up the Python venv, dependencies, and config file |
| `--update` | Re-download scripts from GitHub (preserves `.env`) |
| `--sync` | List Plesk domains and create missing monitors |
| `--sync --dry-run` | Preview what would be created without making changes |
| `--list` | List existing monitors in the Uptime Kuma group |
| `--cleanup` | Remove obsolete monitors and apply off-server handling |
| `--cleanup --dry-run` | Preview removals and off-server changes |
| `--info` | Show available groups and notifications in Uptime Kuma |
| `--cron` | Install a cron job (sync + cleanup, daily at 10am by default) |
| `--uncron` | Remove the cron job |

## Examples

First run after installation:

```bash
uptime-kuma-sync --sync --dry-run  # check what will be created
uptime-kuma-sync --sync            # create the monitors
```

Clean up removed domains:

```bash
uptime-kuma-sync --cleanup --dry-run  # preview
uptime-kuma-sync --cleanup            # actually delete
```

Set up daily automation at 10am:

```bash
uptime-kuma-sync --cron
```

The schedule is configurable via `CRON_SCHEDULE` in `.env` (default: `0 10 * * *`).

## Domain exclusions

Domains matching the `EXCLUDE_PATTERN` regex in `.env` are skipped. Default: `\.plesk\.page$`.

To exclude additional patterns, edit `.env`. Example excluding `.plesk.page` and `staging.*`:

```bash
EXCLUDE_PATTERN="\.(plesk\.page)$|^staging\."
```

## Off-server detection

During `--cleanup`, each domain still present in Plesk is resolved through a
public DNS resolver and compared against this server's interface IPs. A domain
that no longer resolves to any local IP is considered **off-server** (migrated
away, parked elsewhere, etc.). Domains that fail to resolve are left untouched.

> Resolution uses a public resolver (`DNS_RESOLVER`, default `1.1.1.1`) on
> purpose: a Plesk box that is the DNS master for its own zones would otherwise
> always answer with its local IP. Sites behind a proxy/CDN (e.g. Cloudflare)
> resolve to the CDN's IPs and will therefore be flagged off-server.

The action taken is configured via `OFFSERVER_ACTION` in `.env`:

| Value | Behaviour |
|---|---|
| `report` | Only log off-server domains, change nothing (default) |
| `move` | Move the monitor into the off-server group and pause it |
| `pause` | Pause the monitor in place (no group change) |
| `delete` | Delete the monitor (like a domain removed from Plesk) |
| `off` | Disable the feature entirely (no DNS resolution) |

`move` and `pause` are **reversible**: when a domain points back to this
server, its monitor is resumed (and moved back to the main group) on the next
cleanup. Pausing rather than just silencing means an off-server domain stops
being checked at all, so it never alerts — including when it later goes
NXDOMAIN.

### Off-server group (for `move`)

| Setting | Default | Description |
|---|---|---|
| `OFFSERVER_GROUP_NAME` | `Off-server` | Group looked up by name, auto-created if missing |
| `OFFSERVER_GROUP_ID` | *(empty)* | Override: use this existing group ID as-is (no lookup/creation) |
| `OFFSERVER_GROUP_PARENT` | *(empty)* | Where to create the group: empty = top level, or a group ID to nest under |

`--sync` resolves only the domains it is about to create, and **skips creating
monitors for domains that already point elsewhere** (a domain that doesn't
resolve yet is still created — it may be propagating). Reconciling monitors that
later go off-server is `--cleanup`'s job. The default cron runs both.

The off-server (and suspended) actions are reversible because the desired state
of every monitor is recomputed each cleanup: once a domain points home and is
active again, its monitor is moved back to its group, resumed and un-suffixed.
The tool only ever resumes / un-suffixes monitors **it** paused (those carrying
a managed suffix, `OFFSERVER_NAME_SUFFIX` / `SUSPENDED_NAME_SUFFIX`) — a monitor
you paused manually in Kuma is never touched.

## Grouping by owner

`GROUPING_MODE` controls how monitors are laid out into Uptime Kuma groups:

| Value | Behaviour |
|---|---|
| `by-reseller` | One group per reseller (its domains + its clients' domains); admin-owned and direct-customer domains stay in the main group (default) |
| `flat` | All monitors in the main group (`PARENT_GROUP_ID`) |

In `by-reseller` mode, reseller groups are auto-created and named from the
reseller's Plesk login. The owner is resolved from `domains.vendor_id`
(`1` = admin → main group, otherwise the reseller). Settings:

| Setting | Default | Description |
|---|---|---|
| `RESELLER_GROUP_PREFIX` | *(empty)* | Optional prefix for reseller group names (e.g. `Reseller: `) |
| `RESELLER_GROUP_PARENT` | *(empty)* | Where to create reseller groups: empty = top level, or a group ID to nest under |

Existing monitors are moved into the correct group during `--cleanup`.

## Suspended domains

Domains suspended in Plesk (status 16 = by admin, 32 = by reseller) are still
listed. Plesk does not distinguish an accidental suspension (expiry,
non-renewal) from a deliberate one, so a single policy applies via
`SUSPENDED_ACTION`:

| Value | Behaviour |
|---|---|
| `keep` | Keep monitoring and alerting, so an accidental suspension stays visible (default) |
| `pause` | Keep the monitor but pause it (no alert); resumed automatically on reactivation |
| `delete` | Don't monitor suspended domains; recreated when reactivated |

## Updating

```bash
uptime-kuma-sync --update
```

Re-downloads scripts from GitHub. The `.env` config file is never overwritten.

## Logs

Logs are written to `/opt/uptime-kuma-sync/uptime-kuma-sync.log` with automatic rotation. Retention is configurable via `LOG_RETENTION_DAYS` in `.env` (default: 30 days).

## File structure

```
/opt/uptime-kuma-sync/
├── uptime-kuma-sync.sh   # Main script (orchestration)
├── uptime-kuma-sync.py   # Python script (Socket.io communication)
├── .env                  # Configuration (credentials, settings)
├── venv/                 # Python virtual environment
├── domains-list          # Plesk domain list (auto-generated)
└── uptime-kuma-sync.log  # Logs
```

## License

GNU General Public License v3.0
