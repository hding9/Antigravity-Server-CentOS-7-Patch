#!/bin/bash
# fix_vscode_server.sh
# VS Code Remote SSH - CentOS 7 Patch
#
# Replaces VS Code Server's bundled node binary with a wrapper that uses
# a conda/micromamba-installed node, which is built to work on CentOS 7's
# older kernel (3.10) and glibc (2.17).
#
# The patchelf/glibc-replacement approach does NOT work here because:
# - CentOS 7 runs kernel 3.10, but modern glibc (2.42) requires kernel 3.17+
# - The bundled node requires glibc 2.28+, which CentOS 7 doesn't have
# Instead, we install a compatible node via conda-forge and redirect to it.

set -e

CONDA_ENV_NAME="vscode-node"

# Support remote execution via SSH or explicit local execution
if [ -z "$1" ]; then
    echo "❌ Error: Missing execution target."
    echo "Usage: bash $0 <target>"
    echo ""
    echo "Examples:"
    echo "  bash $0 local          # Run on the current machine"
    echo "  bash $0 user@hostname  # Run on a remote server via SSH"
    echo "  bash $0 orpheus        # Run on a remote server via SSH alias"
    exit 1
fi

TARGET="$1"

if [ "$TARGET" != "local" ]; then
    echo "🚀 Connecting to $TARGET and applying the VS Code Server patch remotely..."
    ssh "$TARGET" 'PATH=$PATH:~/.local/bin bash -s local' < "$0" || SSH_EXIT=$?
    SSH_EXIT=${SSH_EXIT:-0}
    if [ "$SSH_EXIT" -eq 0 ]; then
        echo "✅ Patch successfully applied on $TARGET!"
    else
        echo "❌ Failed to apply patch on $TARGET. (exit code: $SSH_EXIT)"
    fi
    exit "$SSH_EXIT"
fi

echo "🚀 Applying the VS Code Server patch locally..."

# Configuration
VSCODE_SERVER_BASE="$HOME/.vscode-server/bin"

# 1. Setup Environment - install a compatible node via conda/micromamba
if command -v micromamba &> /dev/null; then
    MAMBA_CMD="micromamba"
elif command -v conda &> /dev/null; then
    MAMBA_CMD="conda"
else
    echo "❌ Error: Neither conda nor micromamba found. Please install one first."
    exit 1
fi

# Create the conda environment with node if it doesn't exist or node isn't installed
CONDA_NODE=""
if $MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version &> /dev/null; then
    CONDA_NODE=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which node 2>/dev/null)
    echo "✅ Node already installed: $($MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version) at $CONDA_NODE"
else
    echo "📦 Installing Node.js via $MAMBA_CMD..."
    $MAMBA_CMD create -n "$CONDA_ENV_NAME" -c conda-forge nodejs -y 2>&1 | tail -5
    CONDA_NODE=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which node 2>/dev/null)
    NODE_VER=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version 2>/dev/null)
    if [ -z "$CONDA_NODE" ] || [ -z "$NODE_VER" ]; then
        echo "❌ Error: Failed to install Node.js via $MAMBA_CMD."
        exit 1
    fi
    echo "✅ Node.js $NODE_VER installed at $CONDA_NODE"
fi

# 1b. Ensure build tools are available for native module rebuilds
# CentOS 7's GCC 4.8.5 doesn't support C++17, which node-pty requires
CONDA_ENV_BIN=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" bash -c 'echo $CONDA_PREFIX/bin' 2>/dev/null)
if ! $MAMBA_CMD run -n "$CONDA_ENV_NAME" x86_64-conda-linux-gnu-g++ --version &> /dev/null; then
    echo "📦 Installing C++ build tools (for native module rebuilds)..."
    $MAMBA_CMD install -n "$CONDA_ENV_NAME" -c conda-forge gxx_linux-64 python -y 2>&1 | tail -5
fi

# 1c. Ensure modern wget is available (CentOS 7 wget doesn't support --no-config)
CONDA_WGET=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which wget 2>/dev/null)
if [ -z "$CONDA_WGET" ]; then
    echo "📦 Installing modern wget..."
    $MAMBA_CMD install -n "$CONDA_ENV_NAME" -c conda-forge wget -y 2>&1 | tail -5
    CONDA_WGET=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which wget 2>/dev/null)
fi

# Create wget wrapper in ~/.local/bin so VS Code's SSH sessions find it
if [ -n "$CONDA_WGET" ]; then
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/wget" << WGETWRAPPER
#!/bin/bash
exec $CONDA_WGET "\$@"
WGETWRAPPER
    chmod +x "$HOME/.local/bin/wget"
    echo "✅ Modern wget wrapper installed at ~/.local/bin/wget"
fi

# Ensure ~/.local/bin is in PATH for non-login SSH sessions
if ! grep -q 'export PATH=\$HOME/.local/bin:\$PATH' "$HOME/.bashrc" 2>/dev/null; then
    sed -i '1a\# Add ~/.local/bin to PATH for VS Code Remote SSH compatibility\nexport PATH=$HOME/.local/bin:$PATH' "$HOME/.bashrc"
    echo "✅ Added ~/.local/bin to PATH in ~/.bashrc"
fi

# 1d. Configure Codex sandbox for CentOS 7
# Codex CLI uses bwrap (bubblewrap) for sandboxing, which requires user namespaces.
# CentOS 7's kernel 3.10 doesn't support unprivileged user namespaces, causing
# "bwrap: Creating new namespace failed" errors when Codex tries to apply patches.
# Setting sandbox_mode to "danger-full-access" bypasses bwrap entirely.
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ ! -f "$CODEX_CONFIG" ] || ! grep -q 'sandbox_mode' "$CODEX_CONFIG" 2>/dev/null; then
    mkdir -p "$HOME/.codex"
    echo 'sandbox_mode = "danger-full-access"' >> "$CODEX_CONFIG"
    echo "✅ Codex sandbox configured (bwrap bypass for CentOS 7)"
elif grep -q 'sandbox_mode.*=.*"danger-full-access"' "$CODEX_CONFIG" 2>/dev/null; then
    echo "✅ Codex sandbox already configured"
else
    echo "⚠️  Codex config exists with different sandbox_mode — skipping (edit $CODEX_CONFIG manually if needed)"
fi

# 2. Find VS Code Server installations
if [ ! -d "$VSCODE_SERVER_BASE" ]; then
    echo "⚠️  VS Code Server directory $VSCODE_SERVER_BASE not found."
    echo "   Connect via VS Code Remote SSH first to trigger the server download."
    exit 1
fi

COMMIT_DIRS=$(find "$VSCODE_SERVER_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
if [ -z "$COMMIT_DIRS" ]; then
    echo "⚠️  No VS Code Server installations found in $VSCODE_SERVER_BASE."
    exit 1
fi

# 3. Stop any running VS Code server processes
echo "🛑 Stopping running VS Code server processes..."
pkill -f "vscode-server" || true
pkill -f ".vscode-server/bin" || true

# 4. Patch each VS Code Server installation
PATCHED=0
for COMMIT_DIR in $COMMIT_DIRS; do
    COMMIT_HASH=$(basename "$COMMIT_DIR")
    NODE_BIN="$COMMIT_DIR/node"

    # Skip if no node binary present
    if [ ! -f "$NODE_BIN" ] && [ ! -f "$NODE_BIN.original" ]; then
        echo "⏩ Skipping $COMMIT_HASH (no node binary found)"
        continue
    fi

    echo ""
    echo "🔍 Patching VS Code Server: $COMMIT_HASH"

    # Check if already patched (node is a wrapper script)
    if [ -f "$NODE_BIN" ] && head -c 2 "$NODE_BIN" | grep -q "#!"; then
        if grep -q "$CONDA_NODE" "$NODE_BIN" 2>/dev/null; then
            echo "   ✅ Already patched with correct node wrapper"
            PATCHED=$((PATCHED + 1))
            continue
        else
            echo "   🔄 Wrapper exists but points to wrong node, updating..."
            # If .original exists, keep it; otherwise this wrapper is from a previous run
        fi
    fi

    # Back up original node binary (only if it's a real binary, not a wrapper)
    if [ -f "$NODE_BIN" ] && ! head -c 2 "$NODE_BIN" | grep -q "#!"; then
        echo "   📦 Backing up original node binary to node.original"
        mv "$NODE_BIN" "$NODE_BIN.original"
    fi

    # Create wrapper script
    # --experimental-sqlite is required for GitHub Copilot Chat (node:sqlite module)
    echo "   🔨 Creating node wrapper -> $CONDA_NODE"
    cat > "$NODE_BIN" << WRAPPER
#!/bin/bash
exec $CONDA_NODE --experimental-sqlite "\$@"
WRAPPER
    chmod +x "$NODE_BIN"

    # Verify
    NODE_VERSION=$("$NODE_BIN" --version 2>&1) || NODE_VERSION="FAILED"
    echo "   ✅ node --version: $NODE_VERSION"

    # Rebuild node-pty native module (required for VS Code terminal)
    # The bundled pty.node requires glibc 2.28, so we rebuild from source
    PTY_NODE="$COMMIT_DIR/node_modules/node-pty/build/Release/pty.node"
    PTY_NEEDS_REBUILD=0
    if [ -f "$PTY_NODE" ]; then
        if ldd "$PTY_NODE" 2>&1 | grep -q "not found"; then
            PTY_NEEDS_REBUILD=1
        fi
    fi

    if [ "$PTY_NEEDS_REBUILD" -eq 1 ]; then
        echo "   🔨 Rebuilding node-pty native module..."
        PTY_VERSION=$(cat "$COMMIT_DIR/node_modules/node-pty/package.json" 2>/dev/null | grep '"version"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$PTY_VERSION" ]; then
            PTY_VERSION="1.2.0-beta.10"
        fi

        TMPBUILD=$(mktemp -d)
        (
            export PATH="$CONDA_ENV_BIN:$PATH"
            export CXX=x86_64-conda-linux-gnu-g++
            export CC=x86_64-conda-linux-gnu-gcc
            cd "$TMPBUILD"
            npm pack "node-pty@$PTY_VERSION" 2>/dev/null
            tar xzf node-pty-*.tgz 2>/dev/null
            cd package
            npm install --ignore-scripts 2>/dev/null
            npx node-gyp rebuild 2>/dev/null
        )

        BUILT_PTY="$TMPBUILD/package/build/Release/pty.node"
        if [ -f "$BUILT_PTY" ]; then
            cp "$BUILT_PTY" "$PTY_NODE"
            chmod +x "$PTY_NODE"
            echo "   ✅ node-pty rebuilt successfully"
        else
            echo "   ⚠️  node-pty rebuild failed (terminal may not work)"
        fi
        rm -rf "$TMPBUILD"
    else
        echo "   ✅ node-pty native module OK"
    fi

    PATCHED=$((PATCHED + 1))
done

echo ""
if [ "$PATCHED" -gt 0 ]; then
    echo "✅ VS Code Server patching complete ($PATCHED installation(s) patched)."
    echo "   You can now connect via VS Code Remote SSH."
else
    echo "⚠️  No VS Code Server installations were patched."
fi
