#!/bin/bash
# fix_vscode_server.sh
# VS Code Server - CentOS 7 Patch
#
# CentOS 7 ships with glibc 2.17, but VS Code Server's bundled node requires
# glibc 2.28+. This script replaces the bundled node binary with a wrapper that
# runs a node built for glibc 2.17:
#
#   1. Preferred: the *same* Node.js version VS Code bundles, taken from Node's
#      unofficial builds (unofficial-builds.nodejs.org, "glibc-217" flavour).
#      This is required since VS Code 1.141 (Node 24): the server imports
#      node:module APIs that don't exist before Node 22.15, and every
#      conda-forge nodejs >= 22.15 is built against glibc 2.28.
#   2. Fallback: a conda/micromamba-installed node (the newest conda-forge build
#      that still supports glibc 2.17, currently 22.6) for builds where no
#      glibc-2.17 unofficial build exists or the download fails.
#
# conda/micromamba is still needed for the C++ toolchain (node-pty rebuild),
# a modern wget (VS Code's install script), and libstdc++ for vsce-sign.

set -e

CONDA_ENV_NAME="vscode-node"
GLIBC217_NODE_STORE="$HOME/.local/share/vscode-node-glibc217"
UNOFFICIAL_BASE="https://unofficial-builds.nodejs.org/download/release"
# How many VS Code Server builds to keep (newest first); older ones are deleted.
# Every VS Code update downloads a new ~650 MB build and never removes the old
# one. Set KEEP_BUILDS=0 to disable pruning, or raise it if several clients on
# different VS Code versions connect to this machine.
KEEP_BUILDS="${KEEP_BUILDS:-1}"

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
    echo "🚀 Connecting to $TARGET and applying the VS Code Server patch remotely..."
    ssh "$TARGET" "KEEP_BUILDS=$KEEP_BUILDS"' PATH=$PATH:~/.local/bin bash -s local' < "$0" || SSH_EXIT=$?
    SSH_EXIT=${SSH_EXIT:-0}
    if [ "$SSH_EXIT" -eq 0 ]; then
        echo "✅ Patch successfully applied on $TARGET!"
    else
        echo "❌ Failed to apply patch on $TARGET. (exit code: $SSH_EXIT)"
    fi
    exit "$SSH_EXIT"
fi

echo "🚀 Applying the VS Code Server patch locally..."
cd "$HOME"

# Configuration
VSCODE_SERVER_BASE="$HOME/.vscode-server/bin"

# 1. Setup Environment - conda/micromamba for toolchain + fallback node
if command -v micromamba &> /dev/null; then
    MAMBA_CMD="micromamba"
elif command -v conda &> /dev/null; then
    MAMBA_CMD="conda"
else
    echo "❌ Error: Neither conda nor micromamba found. Please install one first."
    exit 1
fi

# Make sure the env exists at all (toolchain, wget, and libstdc++ live here)
if ! $MAMBA_CMD run -n "$CONDA_ENV_NAME" true &> /dev/null; then
    echo "📦 Creating conda environment '$CONDA_ENV_NAME'..."
    $MAMBA_CMD create -n "$CONDA_ENV_NAME" -c conda-forge -y 2>&1 | tail -2
fi

# 1a. Fallback node from conda-forge (newest build that supports glibc 2.17)
CONDA_NODE=""
if $MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version &> /dev/null; then
    CONDA_NODE=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which node 2>/dev/null)
    echo "✅ Conda node available: $($MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version) at $CONDA_NODE"
else
    echo "📦 Installing fallback Node.js via $MAMBA_CMD..."
    $MAMBA_CMD install -n "$CONDA_ENV_NAME" -c conda-forge nodejs -y 2>&1 | tail -5 || true
    CONDA_NODE=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" which node 2>/dev/null) || true
    if [ -n "$CONDA_NODE" ]; then
        echo "✅ Conda node $($MAMBA_CMD run -n "$CONDA_ENV_NAME" node --version) installed at $CONDA_NODE"
    else
        echo "⚠️  Could not install node via $MAMBA_CMD — only glibc-2.17 unofficial builds will be used"
    fi
fi

# 1b. Ensure build tools are available for native module rebuilds
# CentOS 7's GCC 4.8.5 doesn't support C++17, which node-pty requires
CONDA_ENV_BIN=$($MAMBA_CMD run -n "$CONDA_ENV_NAME" bash -c 'echo $CONDA_PREFIX/bin' 2>/dev/null)
CONDA_ENV_LIB="${CONDA_ENV_BIN%/bin}/lib"
if ! $MAMBA_CMD run -n "$CONDA_ENV_NAME" x86_64-conda-linux-gnu-g++ --version &> /dev/null; then
    echo "📦 Installing C++ build tools (for native module rebuilds)..."
    $MAMBA_CMD install -n "$CONDA_ENV_NAME" -c conda-forge gxx_linux-64 python -y 2>&1 | tail -5
fi

# 1c. Ensure modern wget is available (CentOS 7 wget doesn't support --no-config)
# Resolve wget by its path inside the conda env — `which wget` can fall back to
# the ~/.local/bin/wget wrapper from a previous run, producing a wrapper that
# execs itself in an infinite loop.
CONDA_WGET="$CONDA_ENV_BIN/wget"
if [ ! -x "$CONDA_WGET" ]; then
    echo "📦 Installing modern wget..."
    $MAMBA_CMD install -n "$CONDA_ENV_NAME" -c conda-forge wget -y 2>&1 | tail -5
fi
if [ ! -x "$CONDA_WGET" ]; then
    echo "⚠️  wget not found in conda env — skipping wget wrapper"
    CONDA_WGET=""
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

# 1e. Helpers for the glibc-2.17 unofficial Node builds
download() {
    # download <url> <dest-file>
    if [ -n "$CONDA_WGET" ]; then
        "$CONDA_WGET" -q -O "$2" "$1"
    elif command -v curl &> /dev/null; then
        curl -fsSL -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}

bundled_node_version() {
    # bundled_node_version <node-elf-binary>  ->  vX.Y.Z (empty if unknown)
    if command -v strings &> /dev/null; then
        strings "$1" 2>/dev/null | grep -m1 -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
    fi
}

fetch_glibc217_node() {
    # fetch_glibc217_node <vX.Y.Z>  ->  prints the install root on success
    local ver="$1" root="$GLIBC217_NODE_STORE/$1"
    if [ -x "$root/bin/node" ]; then
        echo "$root"
        return 0
    fi
    local tarball="node-$ver-linux-x64-glibc-217.tar.xz"
    local tmp
    tmp=$(mktemp -d)
    echo "   ⬇️  Downloading $tarball from unofficial-builds.nodejs.org" >&2
    if download "$UNOFFICIAL_BASE/$ver/$tarball" "$tmp/$tarball" \
        && download "$UNOFFICIAL_BASE/$ver/SHASUMS256.txt" "$tmp/SHASUMS256.txt" \
        && (cd "$tmp" && grep " $tarball\$" SHASUMS256.txt | sha256sum -c --quiet - >/dev/null 2>&1) \
        && mkdir -p "$root" \
        && tar xJf "$tmp/$tarball" -C "$root" --strip-components=1 \
        && "$root/bin/node" --version >/dev/null 2>&1; then
        rm -rf "$tmp"
        echo "$root"
        return 0
    fi
    rm -rf "$tmp" "$root"
    return 1
}

# 1f. libstdc++ shim for native modules
# VS Code's native .node modules (spdlog, vsda, kerberos, @parcel/watcher...)
# need GLIBCXX_3.4.20+/CXXABI_1.3.9, newer than CentOS 7's libstdc++ (GCC 4.8).
# The conda node pulled in conda's libstdc++ via its own RPATH; the unofficial
# glibc-2.17 node links libstdc++ statically, so nothing provides it. Expose
# just libstdc++ and libgcc_s (nothing else from the conda env) through
# LD_LIBRARY_PATH in the node wrapper. Newer libstdc++ is backward compatible,
# so inheriting it in VS Code terminals is harmless.
NODE_LIBDIR="$GLIBC217_NODE_STORE/lib"
if [ -f "$CONDA_ENV_LIB/libstdc++.so.6" ]; then
    mkdir -p "$NODE_LIBDIR"
    for lib in libstdc++.so.6 libgcc_s.so.1; do
        if [ -f "$CONDA_ENV_LIB/$lib" ] && ! cmp -s "$CONDA_ENV_LIB/$lib" "$NODE_LIBDIR/$lib"; then
            cp -L "$CONDA_ENV_LIB/$lib" "$NODE_LIBDIR/$lib"
        fi
    done
    echo "✅ libstdc++ shim ready at $NODE_LIBDIR"
else
    echo "⚠️  conda libstdc++ not found — native modules may fail with GLIBCXX errors"
    NODE_LIBDIR=""
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

# 3b. Remove superseded builds, keeping the KEEP_BUILDS newest.
# Builds are ordered by product.json's mtime, which tar preserves from the
# release build (the directory mtime is useless: patching touches it).
# Directories without product.json (incomplete downloads) are left alone.
if [ "$KEEP_BUILDS" -gt 0 ]; then
    OLD_DIRS=$(for d in $COMMIT_DIRS; do
        [ -f "$d/product.json" ] && echo "$(stat -c %Y "$d/product.json") $d"
    done | sort -rn | tail -n +$((KEEP_BUILDS + 1)) | cut -d' ' -f2-)
    for d in $OLD_DIRS; do
        case "$d" in "$VSCODE_SERVER_BASE"/?*) ;; *) continue ;; esac
        echo "🧹 Removing old build $(basename "$d") ($(date -d "@$(stat -c %Y "$d/product.json")" +%F), $(du -sh "$d" | cut -f1))"
        rm -rf "$d"
    done
    COMMIT_DIRS=$(find "$VSCODE_SERVER_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# 4. Patch each VS Code Server installation
# Old builds pile up in ~/.vscode-server/bin (one directory per VS Code commit),
# so the per-step log is only printed for installations that actually need
# work; ones that are already fully patched get a single summary line.
say() {
    if [ "$SHOWN" -eq 1 ]; then echo "$1"; else LOG="$LOG$1
"; fi
}
show() {
    if [ "$SHOWN" -eq 0 ]; then
        echo ""
        echo "🔍 Patching VS Code Server: $COMMIT_HASH"
        printf '%s' "$LOG"
        SHOWN=1
    fi
}

PATCHED=0
UNCHANGED=0
for COMMIT_DIR in $COMMIT_DIRS; do
    COMMIT_HASH=$(basename "$COMMIT_DIR")
    NODE_BIN="$COMMIT_DIR/node"

    # Skip if no node binary present
    if [ ! -f "$NODE_BIN" ] && [ ! -f "$NODE_BIN.original" ]; then
        echo "⏩ Skipping $COMMIT_HASH (no node binary found)"
        continue
    fi

    SHOWN=0
    LOG=""

    # Patch vsce-sign (extension signature verification)
    # The bundled binary needs GLIBCXX_3.4.20+, but CentOS 7's libstdc++ stops
    # at 3.4.19 — installs fail with "Signature verification failed with
    # 'UnknownError'". Wrap it to preload the conda env's modern libstdc++.
    VSCE_SIGN="$COMMIT_DIR/node_modules/@vscode/vsce-sign/bin/vsce-sign"
    if [ -f "$VSCE_SIGN" ] && [ -f "$CONDA_ENV_LIB/libstdc++.so.6" ]; then
        if head -c 2 "$VSCE_SIGN" | grep -q "#!"; then
            say "   ✅ vsce-sign already wrapped"
        else
            show
            say "   🔨 Wrapping vsce-sign with conda libstdc++"
            mv "$VSCE_SIGN" "$VSCE_SIGN.original"
            cat > "$VSCE_SIGN" << VSCESIGN
#!/bin/bash
export LD_LIBRARY_PATH=$CONDA_ENV_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $VSCE_SIGN.original "\$@"
VSCESIGN
            chmod +x "$VSCE_SIGN"
            if timeout 5 "$VSCE_SIGN" verify 2>&1 | grep -q "not found"; then
                say "   ⚠️  vsce-sign still failing (extension installs may not work)"
            else
                say "   ✅ vsce-sign runs with patched libstdc++"
            fi
        fi
    fi

    # Pick the node to run this build with.
    # Prefer the exact version VS Code bundles (glibc-2.17 unofficial build),
    # fall back to the conda node.
    ORIG_NODE="$NODE_BIN.original"
    [ -f "$ORIG_NODE" ] || ORIG_NODE="$NODE_BIN"
    BUNDLED_VER=$(bundled_node_version "$ORIG_NODE")
    TARGET_NODE=""
    TARGET_NODE_ROOT=""
    if [ -n "$BUNDLED_VER" ]; then
        say "   ℹ️  Bundled node version: $BUNDLED_VER"
        if TARGET_NODE_ROOT=$(fetch_glibc217_node "$BUNDLED_VER"); then
            TARGET_NODE="$TARGET_NODE_ROOT/bin/node"
            say "   ✅ Using glibc-2.17 build of node $BUNDLED_VER"
        else
            say "   ⚠️  No glibc-2.17 unofficial build available for $BUNDLED_VER"
        fi
    else
        say "   ⚠️  Could not determine bundled node version"
    fi
    if [ -z "$TARGET_NODE" ]; then
        if [ -z "$CONDA_NODE" ]; then
            show
            say "   ❌ No usable node for this build, skipping"
            continue
        fi
        TARGET_NODE="$CONDA_NODE"
        TARGET_NODE_ROOT="${CONDA_ENV_BIN%/bin}"
        say "   ↩️  Falling back to conda node $("$CONDA_NODE" --version 2>/dev/null)"
    fi

    # node:sqlite (used by GitHub Copilot Chat) is behind a flag before Node 23
    NODE_FLAGS=""
    NODE_MAJOR=$("$TARGET_NODE" -e 'process.stdout.write(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)
    if [ "$NODE_MAJOR" -lt 23 ]; then
        NODE_FLAGS="--experimental-sqlite"
    fi

    # Desired wrapper content (LD_LIBRARY_PATH is only prepended once so nested
    # node spawns don't grow it)
    WRAPPER_CONTENT="#!/bin/bash"
    if [ -n "$NODE_LIBDIR" ]; then
        WRAPPER_CONTENT="$WRAPPER_CONTENT
case \":\$LD_LIBRARY_PATH:\" in *\":$NODE_LIBDIR:\"*) ;; *) export LD_LIBRARY_PATH=$NODE_LIBDIR\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} ;; esac"
    fi
    WRAPPER_CONTENT="$WRAPPER_CONTENT
exec $TARGET_NODE${NODE_FLAGS:+ $NODE_FLAGS} \"\$@\""

    # Check if already patched (node is a wrapper script with the desired content)
    if [ -f "$NODE_BIN" ] && head -c 2 "$NODE_BIN" | grep -q "#!" && [ "$(cat "$NODE_BIN")" = "$WRAPPER_CONTENT" ]; then
        say "   ✅ Already patched with correct node wrapper"
    else
        show
        # Back up original node binary (only if it's a real binary, not a wrapper)
        if [ -f "$NODE_BIN" ] && ! head -c 2 "$NODE_BIN" | grep -q "#!"; then
            say "   📦 Backing up original node binary to node.original"
            mv "$NODE_BIN" "$NODE_BIN.original"
        elif [ -f "$NODE_BIN" ]; then
            say "   🔄 Wrapper exists but is outdated, updating..."
        fi

        say "   🔨 Creating node wrapper -> $TARGET_NODE"
        printf '%s\n' "$WRAPPER_CONTENT" > "$NODE_BIN"
        chmod +x "$NODE_BIN"
    fi

    # Verify
    NODE_VERSION=$("$NODE_BIN" --version 2>&1) || NODE_VERSION="FAILED"
    [ "$NODE_VERSION" = "FAILED" ] && show
    say "   ✅ node --version: $NODE_VERSION"

    # Rebuild node-pty native module (required for VS Code terminal) when the
    # bundled pty.node has missing glibc symbols or doesn't load in TARGET_NODE
    PTY_NODE="$COMMIT_DIR/node_modules/node-pty/build/Release/pty.node"
    PTY_NEEDS_REBUILD=0
    if [ -f "$PTY_NODE" ]; then
        if ldd "$PTY_NODE" 2>&1 | grep -q "not found"; then
            PTY_NEEDS_REBUILD=1
        elif ! "$NODE_BIN" -e "require('$PTY_NODE')" >/dev/null 2>&1; then
            PTY_NEEDS_REBUILD=1
        fi
    fi

    if [ "$PTY_NEEDS_REBUILD" -eq 1 ]; then
        show
        say "   🔨 Rebuilding node-pty native module..."
        PTY_VERSION=$(cat "$COMMIT_DIR/node_modules/node-pty/package.json" 2>/dev/null | grep '"version"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$PTY_VERSION" ]; then
            PTY_VERSION="1.2.0-beta.10"
        fi

        # Build against the headers shipped with TARGET_NODE when available
        GYP_ARGS=""
        if [ -f "$TARGET_NODE_ROOT/include/node/node_api.h" ]; then
            GYP_ARGS="--nodedir=$TARGET_NODE_ROOT"
        fi

        TMPBUILD=$(mktemp -d)
        (
            export PATH="$(dirname "$TARGET_NODE"):$CONDA_ENV_BIN:$PATH"
            export CXX=x86_64-conda-linux-gnu-g++
            export CC=x86_64-conda-linux-gnu-gcc
            cd "$TMPBUILD"
            npm pack "node-pty@$PTY_VERSION" >/dev/null 2>&1
            tar xzf node-pty-*.tgz 2>/dev/null
            cd package
            npm install --ignore-scripts >/dev/null 2>&1
            npx node-gyp rebuild $GYP_ARGS >/dev/null 2>&1
        )

        BUILT_PTY="$TMPBUILD/package/build/Release/pty.node"
        if [ -f "$BUILT_PTY" ] && "$NODE_BIN" -e "require('$BUILT_PTY')" >/dev/null 2>&1; then
            cp "$BUILT_PTY" "$PTY_NODE"
            chmod +x "$PTY_NODE"
            say "   ✅ node-pty rebuilt successfully"
        else
            say "   ⚠️  node-pty rebuild failed (terminal may not work)"
        fi
        rm -rf "$TMPBUILD"
    else
        say "   ✅ node-pty native module OK"
    fi

    if [ "$SHOWN" -eq 1 ]; then
        PATCHED=$((PATCHED + 1))
    else
        UNCHANGED=$((UNCHANGED + 1))
        NOTE="node $NODE_VERSION"
        [ "$NODE_VERSION" = "$BUNDLED_VER" ] || NOTE="$NOTE, bundled ${BUNDLED_VER:-unknown}"
        echo "✅ $COMMIT_HASH already patched ($NOTE)"
    fi
done

echo ""
if [ $((PATCHED + UNCHANGED)) -gt 0 ]; then
    echo "✅ VS Code Server patching complete ($PATCHED newly patched, $UNCHANGED already up to date)."
    echo "   You can now connect via VS Code Remote SSH."
else
    echo "⚠️  No VS Code Server installations were patched."
fi
