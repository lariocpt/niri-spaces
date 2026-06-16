#!/usr/bin/env bash
# Installation script for niri-spaces
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/niri-spaces"
BIN_DIR="$HOME/.local/bin"

echo "Installing niri-spaces..."

# 1. Create target directories
mkdir -p "$CONFIG_DIR/spaces" "$CONFIG_DIR/templates" "$BIN_DIR"

# 2. Copy configurations
cp "$REPO_DIR/autostart" "$CONFIG_DIR/autostart"
cp "$REPO_DIR/spaces/"*.space "$CONFIG_DIR/spaces/"
cp "$REPO_DIR/templates/"*.space "$CONFIG_DIR/templates/"

# 3. Create symlinks in local bin
ln -sf "$REPO_DIR/niri-spaces" "$BIN_DIR/niri-spaces"
ln -sf "$REPO_DIR/space-splash" "$BIN_DIR/space-splash"

# 4. Add Niri keybind if not already present
NIRI_CONFIG="$HOME/.config/niri/config.kdl"
if [ -f "$NIRI_CONFIG" ]; then
    if ! grep -q 'niri-spaces' "$NIRI_CONFIG"; then
        echo "Adding Mod+Ctrl+Shift+S shortcut to Niri config..."
        sed -i '/Mod+Shift+P { power-off-monitors; }/a \    Mod+Ctrl+Shift+S hotkey-overlay-title="Niri Spaces: Menu" { spawn "niri-spaces" "menu"; }' "$NIRI_CONFIG"
    else
        echo "Niri keybind already exists in config.kdl."
    fi
else
    echo "Warning: Niri config.kdl not found at $NIRI_CONFIG"
fi

# 5. Enable on startup
STARTUP_SH="$HOME/.config/niri/startup.sh"
if [ -f "$STARTUP_SH" ]; then
    if grep -q 'niri-wspaces-loader' "$STARTUP_SH"; then
        echo "Updating Niri startup.sh to use niri-spaces..."
        sed -i 's|niri-wspaces-loader.*|niri-spaces start|' "$STARTUP_SH"
    elif ! grep -q 'niri-spaces start' "$STARTUP_SH"; then
        echo "Appending niri-spaces start to Niri startup.sh..."
        echo -e "\n# Run generic spaces loader\nniri-spaces start" >> "$STARTUP_SH"
    fi
else
    echo "Warning: Niri startup.sh not found at $STARTUP_SH"
fi

echo "niri-spaces installed successfully!"
