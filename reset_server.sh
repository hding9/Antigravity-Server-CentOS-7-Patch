#!/bin/bash
# reset_server.sh
# Antigravity Server CentOS 7 Patch

set -e

echo "🛑 Stopping any running Antigravity server processes..."
pkill -f antigravity-server || true

echo "🧹 Removing ~/.antigravity-server directory..."
rm -rf "$HOME/.antigravity-server"

echo "🐍 Removing 'antigravity-node' Conda environment..."
# Detect manager
if command -v micromamba &> /dev/null; then
    micromamba remove -n antigravity-node --all -y || true
elif command -v conda &> /dev/null; then
    conda remove -n antigravity-node --all -y || true
else
    echo "⚠️  No conda/micromamba found, skipping environment removal."
fi

echo "✨ Server reset to initial state (Antigravity not installed)."
echo "   You can now connect via VS Code to re-download the fresh server files."
