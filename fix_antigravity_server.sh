#!/bin/bash
# fix_antigravity_server.sh
# Antigravity Server CentOS 7 Patch

set -e

# Support remote execution via SSH or explicit local execution
if [ -z "$1" ]; then
    echo "❌ Error: Missing execution target."
    echo "Usage: bash $0 <target>"
    echo ""
    echo "Examples:"
    echo "  bash $0 local          # Run on the current machine"
    echo "  bash $0 user@hostname  # Run on a remote server via SSH"
    exit 1
fi

TARGET="$1"

if [ "$TARGET" != "local" ]; then
    echo "🚀 Connecting to $TARGET and applying the Antigravity patch remotely..."
    ssh "$TARGET" 'PATH=$PATH:~/.local/bin bash -s local' < "$0" || SSH_EXIT=$?
    SSH_EXIT=${SSH_EXIT:-0}
    if [ "$SSH_EXIT" -eq 0 ]; then
        echo "✅ Patch successfully applied on $TARGET!"
    else
        echo "❌ Failed to apply patch on $TARGET. (exit code: $SSH_EXIT)"
    fi
    exit "$SSH_EXIT"
fi

echo "🚀 Applying the Antigravity patch locally..."
# Configuration
SERVER_DIR="$HOME/.antigravity-server/bin"

# Fetch latest release version from MikeWang000000/vscode-server-centos7 dynamically
REPO_URL="https://github.com/MikeWang000000/vscode-server-centos7"
LATEST_VERSION=""

# Method 1a: curl -w redirect_url (most reliable, works on old curl)
if [ -z "$LATEST_VERSION" ] && command -v curl &> /dev/null; then
    LATEST_VERSION=$(curl -s -o /dev/null -w "%{redirect_url}" "$REPO_URL/releases/latest" 2>/dev/null | sed 's/.*tag\///' | tr -d '\r\n') || true
fi

# Method 1b: curl -I Location header fallback
if [ -z "$LATEST_VERSION" ] && command -v curl &> /dev/null; then
    LATEST_VERSION=$(curl -s -I "$REPO_URL/releases/latest" 2>/dev/null | grep -i '^location:' | sed 's/.*tag\///' | tr -d '\r\n') || true
fi

# Method 1c: wget redirect parsing
if [ -z "$LATEST_VERSION" ] && command -v wget &> /dev/null; then
    LATEST_VERSION=$(wget --max-redirect=0 "$REPO_URL/releases/latest" 2>&1 | grep -i 'Location:' | sed 's/.*tag\///' | sed 's/ \[following\]//' | tr -d '\r\n') || true
fi


# Validate: version should look like X.Y.Z
if [ -n "$LATEST_VERSION" ]; then
    LATEST_VERSION=$(echo "$LATEST_VERSION" | grep -oE '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1) || true
fi

if [ -z "$LATEST_VERSION" ]; then
    echo "⚠️  Could not fetch latest release version. Falling back to hardcoded version 1.111.0"
    VERSION="1.111.0"
else
    # Strip any potential 'v' prefix if it exists in the tag name
    VERSION="${LATEST_VERSION#v}"
    echo "ℹ️  Found latest library release: $VERSION"
fi

RELEASE_URL="https://github.com/MikeWang000000/vscode-server-centos7/releases/download/${VERSION}/vscode-server_${VERSION}_x64.tar.gz"
LIB_STORE="$HOME/.antigravity-server/lib-glibc-2.28"

# 1. Setup Environment (Only for patchelf)
if command -v micromamba &> /dev/null; then
    MAMBA_CMD="micromamba"
elif command -v conda &> /dev/null; then
    MAMBA_CMD="conda"
else
    echo "❌ Error: Neither conda nor micromamba found. Please install one first."
    exit 1
fi

echo "📦 Ensuring 'patchelf' is installed..."
$MAMBA_CMD install -n antigravity-node -c conda-forge patchelf -y 2>/dev/null || true

# 2. Download and Extract Libraries (GLIBC 2.28)
VALID_LIB=0
if [ -d "$LIB_STORE" ]; then
    # Look for either the extracted tarball path or the source-compiled installation path
    if find "$LIB_STORE" -name "ld-linux-x86-64.so.2" -o -name "ld-2.28.so" | grep -q .; then
        VALID_LIB=1
        echo "✅ Libraries confirmed present in $LIB_STORE"
    else
        echo "⚠️  Library folder corrupt or empty. Cleaning up..."
        rm -rf "$LIB_STORE"
    fi
fi

if [ "$VALID_LIB" -eq 0 ]; then
    echo "⬇️  Downloading GCC/GLIBC 2.28 libraries..."
    mkdir -p "$LIB_STORE"
    if command -v wget &> /dev/null; then
        wget -L -O "$LIB_STORE/libs.tar.gz" "$RELEASE_URL"
    else
        curl -L -o "$LIB_STORE/libs.tar.gz" "$RELEASE_URL"
    fi
    
    if [ ! -f "$LIB_STORE/libs.tar.gz" ]; then
         echo "❌ Error: Download failed."
         exit 1
    fi
    
    echo "📦 Extracting libraries..."
    TEMP_EXTRACT=$(mktemp -d)
    tar xzf "$LIB_STORE/libs.tar.gz" -C "$TEMP_EXTRACT"
    
    GNU_DIR=$(find "$TEMP_EXTRACT" -name "gnu" -type d | head -n 1)
    if [ -z "$GNU_DIR" ]; then
        echo "❌ Error: Could not find 'gnu' folder in tarball."
        exit 1
    fi
    
    cp -a "$GNU_DIR"/* "$LIB_STORE/"
    rm -rf "$TEMP_EXTRACT"
    rm "$LIB_STORE/libs.tar.gz"
    echo "✅ Libraries installed."
fi

# 3. Configure Paths
# Find critical libs dynamically
INTERPRETER=$(find "$LIB_STORE" -name "ld-linux-x86-64.so.2" | head -n 1)
STDCPP=$(find "$LIB_STORE" -name "libstdc++.so.6" | head -n 1)

if [ -z "$INTERPRETER" ]; then echo "❌ Error: ld-linux not found"; exit 1; fi
if [ -z "$STDCPP" ]; then echo "❌ Error: libstdc++ not found"; exit 1; fi

INTERPRETER_DIR=$(dirname "$INTERPRETER")
STDCPP_DIR=$(dirname "$STDCPP")

echo "ℹ️  Interpreter Path: $INTERPRETER"
echo "ℹ️  LibStdC++ Path:   $STDCPP_DIR"

# RPATH: Include both sysroot locations
# We prioritise the interpreter dir (glibc) then stdcpp
NEW_RPATH="$INTERPRETER_DIR:$STDCPP_DIR"

# 4. Stop Server
pkill -f antigravity-server || true

# 5. Patch Binaries
if [ ! -d "$SERVER_DIR" ]; then
    echo "⚠️  Server directory $SERVER_DIR not found. Connect via Antigravity to download it."
    exit 1
fi

EXTENSIONS_DIR="$HOME/.antigravity-server/extensions"
echo "🔍 Patching binaries..."

DIRS_TO_SEARCH="$SERVER_DIR"
if [ -d "$EXTENSIONS_DIR" ]; then
    DIRS_TO_SEARCH="$DIRS_TO_SEARCH $EXTENSIONS_DIR"
fi

# Pass 0: Unwrap 'node' if a wrapper was left behind
for node_bin in $(find "$SERVER_DIR" -name "node" -type f 2>/dev/null); do
    if [ -f "$node_bin.real" ]; then
        echo "   🧹 Removing wrapper and restoring binary: $node_bin"
        rm "$node_bin"
        mv "$node_bin.real" "$node_bin"
    elif [ -f "$node_bin.original" ]; then
        echo "   🧹 Removing wrapper and restoring binary: $node_bin"
        rm "$node_bin"
        mv "$node_bin.original" "$node_bin"
    elif head -c 2 "$node_bin" | grep -q "#!"; then
        echo "   🗑️  Deleting orphaned wrapper: $node_bin"
        rm "$node_bin"
    fi
done

# Pass 1: Patch executables
for exec_file in $(find $DIRS_TO_SEARCH -type f -perm /111 \
    ! -name "*.node" ! -name "*.so" ! -name "*.real" ! -name "*.original" 2>/dev/null); do
    # Skip scripts
    if head -c 2 "$exec_file" 2>/dev/null | grep -q "#!"; then continue; fi
    # Skip non-ELF files (e.g. .wasm)
    if ! $MAMBA_CMD run -n antigravity-node patchelf --print-interpreter "$exec_file" >/dev/null 2>&1; then
        continue
    fi
    echo "   🔨 Patching: $exec_file"
    $MAMBA_CMD run -n antigravity-node patchelf --set-rpath "$NEW_RPATH" --force-rpath "$exec_file" || true
    $MAMBA_CMD run -n antigravity-node patchelf --set-interpreter "$INTERPRETER" "$exec_file" || true
done

# Pass 2: Patch .node native modules
for native_mod in $(find $DIRS_TO_SEARCH -name "*.node" -type f 2>/dev/null); do
    if ! readelf -h "$native_mod" >/dev/null 2>&1; then continue; fi
    echo "   🔨 Patching module: $native_mod"
    $MAMBA_CMD run -n antigravity-node patchelf --set-rpath "$NEW_RPATH" --force-rpath "$native_mod" || true
done

echo "✅ Patching complete."
echo "   RPATH is set to internal libs. Terminal should work now."
