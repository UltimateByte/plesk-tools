#!/bin/bash
# =============================================================================
# install.sh - Setup Python environment for uptime-kuma-sync
# Author: LRob - https://www.lrob.fr/
# License: MIT
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/uptime-kuma-sync"

echo "=== Uptime Kuma Sync - Installation ==="

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Install python3-venv if needed
echo "Checking python3-venv..."
if ! python3 -m venv --help &>/dev/null; then
    echo "Installing python3-venv..."
    apt update
    apt install -y python3-venv
fi

# Create directory
echo "Creating $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# Create venv
echo "Creating Python virtual environment..."
python3 -m venv "$INSTALL_DIR/venv"

# Install dependencies
echo "Installing Python dependencies..."
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install "python-socketio[client]" websocket-client

echo ""
echo "=== Installation complete ==="
echo ""
echo "Next steps:"
echo "1. Copy uptime-kuma-sync.py to $INSTALL_DIR/"
echo "2. Edit the configuration section in the script and make it executable (chmod +x)"
echo "3. Run: $INSTALL_DIR/uptime-kuma-sync.py --list"
echo ""
echo "Optional: Create a symlink for easier access:"
echo "  ln -s $INSTALL_DIR/uptime-kuma-sync.py /usr/local/bin/uptime-kuma-sync"
