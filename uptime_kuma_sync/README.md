# Uptime Kuma Sync

Automatically sync active domains from a Plesk server to HTTP monitors in [Uptime Kuma](https://github.com/louislam/uptime-kuma).

A single bash script handles everything: installation, updates, Plesk domain listing, sync, cleanup, and cron scheduling.

## Features

- Instant domain listing via Plesk database (no HTTP requests)
- Automatic www / non-www preference detection from Plesk SEO redirect settings
- Creates missing monitors in Uptime Kuma via Socket.io
- Removes obsolete monitors (domains removed from Plesk)
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
```

Edit the configuration section at the top of the script:

```bash
nano /opt/uptime-kuma-sync/uptime-kuma-sync.sh
```

Variables to set:

```bash
UPTIME_KUMA_URL="https://your-uptime-kuma-instance.com"
USERNAME="admin"
PASSWORD="your-password"
PARENT_GROUP_ID=1            # Parent group ID in Uptime Kuma
DEFAULT_NOTIFICATION_IDS="1" # Notification IDs (space-separated)
```

Then run any command — the Python venv and dependencies will be installed automatically on first run:

```bash
/opt/uptime-kuma-sync/uptime-kuma-sync.sh --sync --dry-run
```

A symlink `/usr/local/bin/uptime-kuma-sync` is created automatically.

## Usage

```
uptime-kuma-sync [OPTION]
```

| Option | Description |
|---|---|
| `--install` | Set up the Python venv, dependencies, and Python script |
| `--update` | Re-download scripts from GitHub (preserves config) |
| `--sync` | List Plesk domains and create missing monitors |
| `--sync --dry-run` | Preview what would be created without making changes |
| `--list` | List existing monitors in the Uptime Kuma group |
| `--cleanup` | Preview obsolete monitors to be removed |
| `--cleanup-confirm` | Remove obsolete monitors and their data |
| `--cron` | Install a cron job (daily at 10am by default) |
| `--uncron` | Remove the cron job |

## Examples

First run after installation:

```bash
uptime-kuma-sync --sync --dry-run  # check what will be created
uptime-kuma-sync --sync            # create the monitors
```

Clean up removed domains:

```bash
uptime-kuma-sync --cleanup          # preview
uptime-kuma-sync --cleanup-confirm  # actually delete
```

Set up daily automation at 10am:

```bash
uptime-kuma-sync --cron
```

The schedule is configurable via the `CRON_SCHEDULE` variable at the top of the script (default: `0 10 * * *`).

## Domain exclusions

Domains matching the `EXCLUDE_PATTERN` regex are skipped. Default: `\.plesk\.page$`.

To exclude additional patterns, edit the variable. Example excluding `.plesk.page` and `staging.*`:

```bash
EXCLUDE_PATTERN="\.(plesk\.page)$|^staging\."
```

## Updating

```bash
uptime-kuma-sync --update
```

Re-downloads scripts from GitHub and injects the existing configuration into the new version.

## Logs

Logs are written to `/opt/uptime-kuma-sync/uptime-kuma-sync.log` with automatic rotation. Retention is configurable via `LOG_RETENTION_DAYS` (default: 30 days).

## File structure

```
/opt/uptime-kuma-sync/
├── uptime-kuma-sync.sh   # Main script (config + orchestration)
├── uptime-kuma-sync.py   # Python script (Socket.io communication)
├── venv/                 # Python virtual environment
├── domains-list          # Plesk domain list (auto-generated)
└── uptime-kuma-sync.log  # Logs
```

## License

GNU General Public License v3.0
