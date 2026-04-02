#!/bin/bash
# reset_server.sh
# Reset Antigravity Server and/or VS Code Server installations on CentOS 7

set -e

# Support remote execution via SSH if a hostname is provided
if [ -n "$1" ]; then
    echo "🚀 Connecting to $1 and resetting server installations remotely..."
    ssh "$1" 'PATH=$PATH:~/.local/bin bash -s' < "$0" || SSH_EXIT=$?
    SSH_EXIT=${SSH_EXIT:-0}
    if [ "$SSH_EXIT" -eq 0 ]; then
        echo "✅ Reset successfully completed on $1!"
    else
        echo "❌ Failed to reset on $1."
    fi
    exit "$SSH_EXIT"
fi

# Detect conda/micromamba
if command -v micromamba &> /dev/null; then
    MAMBA_CMD="micromamba"
elif command -v conda &> /dev/null; then
    MAMBA_CMD="conda"
else
    MAMBA_CMD=""
fi

# --- Antigravity Server ---
echo ""
echo "=== Antigravity Server ==="

echo "🛑 Stopping any running Antigravity server processes..."
pkill -f antigravity-server || true

if [ -d "$HOME/.antigravity-server" ]; then
    echo "🧹 Removing ~/.antigravity-server directory..."
    rm -rf "$HOME/.antigravity-server"
else
    echo "   (not installed, skipping)"
fi

if [ -n "$MAMBA_CMD" ]; then
    echo "🐍 Removing 'antigravity-node' Conda environment..."
    $MAMBA_CMD remove -n antigravity-node --all -y 2>/dev/null || true
fi

# --- VS Code Server ---
echo ""
echo "=== VS Code Server ==="

echo "🛑 Stopping any running VS Code server processes..."
pkill -f vscode-server || true
pkill -f ".vscode-server/bin" || true

if [ -d "$HOME/.vscode-server" ]; then
    echo "🧹 Removing ~/.vscode-server directory..."
    rm -rf "$HOME/.vscode-server"
else
    echo "   (not installed, skipping)"
fi

if [ -n "$MAMBA_CMD" ]; then
    echo "🐍 Removing 'vscode-node' Conda environment..."
    $MAMBA_CMD remove -n vscode-node --all -y 2>/dev/null || true
fi

# --- Cleanup shared resources ---
echo ""
echo "=== Shared Resources ==="

# Remove wget wrapper if it exists
if [ -f "$HOME/.local/bin/wget" ] && grep -qE "(conda|micromamba)" "$HOME/.local/bin/wget" 2>/dev/null; then
    echo "🧹 Removing conda wget wrapper from ~/.local/bin/wget..."
    rm -f "$HOME/.local/bin/wget"
fi

if [ -z "$MAMBA_CMD" ]; then
    echo "⚠️  No conda/micromamba found, skipping environment removal."
fi

echo ""
echo "✨ Server installations reset to initial state."
echo "   Connect via VS Code or Antigravity to re-download fresh server files."
