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
LATEST_VERSION=""

# Method 1: Try HTTP redirect parsing to bypass GitHub API rate limits
if command -v curl &> /dev/null; then
    LATEST_VERSION=$(curl -s -I https://github.com/MikeWang000000/vscode-server-centos7/releases/latest | grep -i '^location:' | sed 's/.*tag\///' | tr -d '\r') || true
elif command -v wget &> /dev/null; then
    LATEST_VERSION=$(wget --max-redirect=0 https://github.com/MikeWang000000/vscode-server-centos7/releases/latest 2>&1 | grep -i 'Location:' | sed 's/.*tag\///' | tr -d '\r') || true
fi

# Method 2: Fallback to git ls-remote if available
if [ -z "$LATEST_VERSION" ] && command -v git &> /dev/null; then
    LATEST_VERSION=$(git ls-remote --tags --refs https://github.com/MikeWang000000/vscode-server-centos7.git 2>/dev/null | grep -v '\^{}' | sed -E 's/.*refs\/tags\///' | sort -V | tail -n 1) || true
fi

# Method 3: Fallback to GitHub API (may hit rate limits)
if [ -z "$LATEST_VERSION" ]; then
    API_RESPONSE=""
    if command -v curl &> /dev/null; then
        API_RESPONSE=$(curl -s https://api.github.com/repos/MikeWang000000/vscode-server-centos7/releases/latest 2>/dev/null) || true
    elif command -v wget &> /dev/null; then
        API_RESPONSE=$(wget -qO- https://api.github.com/repos/MikeWang000000/vscode-server-centos7/releases/latest 2>/dev/null) || true
    fi
    
    if [ -n "$API_RESPONSE" ]; then
        if command -v python3 &> /dev/null; then
            LATEST_VERSION=$(echo "$API_RESPONSE" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('tag_name',''))" 2>/dev/null) || true
        elif command -v jq &> /dev/null; then
            LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name // empty' 2>/dev/null) || true
        else
            LATEST_VERSION=$(echo "$API_RESPONSE" | grep '"tag_name":' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/') || true
        fi
    fi
fi

if [ -z "$LATEST_VERSION" ]; then
    echo "⚠️  Could not fetch latest release version from GitHub API. Falling back to hardcoded version 1.109.5"
    VERSION="1.109.5"
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
    echo "⚠️  Server directory $SERVER_DIR not found. Connect via VS Code to download it."
    exit 1
fi

EXTENSIONS_DIR="$HOME/.antigravity-server/extensions"
echo "🔍 Patching binaries..."

patch_elf_file() {
    local file=$1
    local is_exec=$2 
    
    if [[ ! -f "$file" ]]; then return; fi
    
    if [[ "$is_exec" -eq 1 ]]; then
       # Skip static binaries
       if ! $MAMBA_CMD run -n antigravity-node patchelf --print-interpreter "$file" >/dev/null 2>&1; then
           echo "   ⏩ Skipping (static): $file"
           return
       fi
       # REMOVED: "Already patched" check. We FORCE patch now to ensure correctness.
    else
       if ! readelf -h "$file" >/dev/null 2>&1; then return; fi
    fi

    echo "   🔨 Patching: $file"
    $MAMBA_CMD run -n antigravity-node patchelf --set-rpath "$NEW_RPATH" --force-rpath "$file"
    
    if [[ "$is_exec" -eq 1 ]]; then
        $MAMBA_CMD run -n antigravity-node patchelf --set-interpreter "$INTERPRETER" "$file"
    fi
}

# Cleanup Wrapper function
unwrap_node_binary() {
    local node_path=$1
    
    # Check if 'node.real' exists (residue from wrapper strategy)
    if [ -f "$node_path.real" ]; then
        echo "   🧹 Removing wrapper and restoring binary: $node_path"
        rm "$node_path" # Delete the wrapper script
        mv "$node_path.real" "$node_path" # Restore executable
    elif head -c 2 "$node_path" | grep -q "#!"; then
        # It's a script but no .real? Suspicious. Check if it's OUR wrapper.
        if grep -q "antigravity wrapper" "$node_path"; then
             echo "   🗑️  Deleting orphaned wrapper: $node_path"
             rm "$node_path"
             # If .real is missing, we might be in trouble, but hopefully scp restored it or we download again.
             # Assume user didn't lose the binary.
        fi
    fi
}

DIRS_TO_SEARCH="$SERVER_DIR"
if [ -d "$EXTENSIONS_DIR" ]; then
    DIRS_TO_SEARCH="$DIRS_TO_SEARCH $EXTENSIONS_DIR"
fi

# Pass 0: Unwrap 'node' FIRST
find "$SERVER_DIR" -name "node" -type f | while read -r node_bin; do
    unwrap_node_binary "$node_bin"
done

# Pass 1: Patch everything (Now 'node' is a real binary again)
find $DIRS_TO_SEARCH -type f -perm /111 \
    ! -name "*.node" ! -name "*.so" ! -name "*.real" | while read -r exec_file; do
    if head -c 2 "$exec_file" | grep -q "#!"; then continue; fi
    patch_elf_file "$exec_file" 1
done

# Pass 2: Patch .node modules
find $DIRS_TO_SEARCH -name "*.node" -type f | while read -r native_mod; do
    patch_elf_file "$native_mod" 0
done

echo "✅ Patching complete (Wrapper Removed)."
echo "   RPATH is set to internal libs. Terminal should work now."
