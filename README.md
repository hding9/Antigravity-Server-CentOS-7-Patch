# CentOS 7 Server Patch

## Overview
A collection of scripts that patch **Antigravity Server** and **VS Code Server** binaries to run on legacy Linux systems like **CentOS 7**, which ship with `glibc 2.17` — too old for the `glibc >= 2.28` required by modern server binaries.

Both servers fail for the same reason: their bundled `node` and native modules are linked against `glibc 2.28+`, which CentOS 7 does not have.

## Why Two Different Strategies?

The simpler approach is to replace the bundled `node` with a compatible build from conda — this is what `fix_vscode_server.sh` does. However, this **does not work for Antigravity Server**. The node wrapper alone is not enough; Antigravity's native modules (`.node` files) also require glibc 2.28+ and crash at runtime.

The patchelf approach used by `fix_antigravity_server.sh` solves this by side-loading glibc 2.28 libraries and rewriting the ELF headers of **every** binary and native module, so they all use the modern libraries instead of the system ones.

| Script | Target | Strategy | Why |
|---|---|---|---|
| `fix_antigravity_server.sh` | Antigravity Server | Side-load glibc 2.28 + patchelf all binaries | Node wrapper alone causes crashes — native modules also need glibc 2.28+ |
| `fix_vscode_server.sh` | VS Code Server | Replace bundled node with conda-installed build | Simpler; sufficient for VS Code Server |

## Acknowledgements & Credits
**Huge thanks to [MikeWang000000/vscode-server-centos7](https://github.com/MikeWang000000/vscode-server-centos7).**

The Antigravity fix uses the pre-compiled `glibc` and `gcc` runtime libraries provided by the releases in that repository.

## How It Works

### Antigravity Server (`fix_antigravity_server.sh`)
Uses a **"Side-Loading & Patching"** strategy:

1.  **Fetch Latest Version**: Detects the latest library release from `MikeWang000000/vscode-server-centos7` via curl/wget redirect following.
2.  **Download & Extract**: `glibc 2.28` runtime libraries are saved to `~/.antigravity-server/lib-glibc-2.28`.
3.  **Patch**: Uses `patchelf` to modify ELF headers of all server binaries and native `.node` modules:
    *   **Interpreter**: Changed to the side-loaded `ld-linux-x86-64.so.2`.
    *   **RPATH**: Changed to point to the side-loaded library directory.

### VS Code Server (`fix_vscode_server.sh`)
Uses a **"Node Replacement"** strategy:

1.  **Install Compatible Node**: Creates a conda environment (`vscode-node`) with a Node.js build compatible with CentOS 7.
2.  **Install Build Tools**: Installs `gxx_linux-64` from conda-forge for rebuilding native modules.
3.  **Install Modern wget**: A conda-provided wget wrapper is installed to `~/.local/bin/` (CentOS 7's system wget is too old for VS Code's download scripts).
4.  **Patch Server Installations**: Backs up the original `node` binary and replaces it with a wrapper pointing to the conda node.
5.  **Rebuild node-pty**: If the bundled `pty.node` has missing glibc symbols, it is rebuilt from source.
6.  **Configure Codex**: Sets `sandbox_mode = "danger-full-access"` in `~/.codex/config.toml` to bypass `bwrap` (requires unprivileged user namespaces, unavailable on CentOS 7's kernel 3.10).

## Prerequisites
*   **Micromamba** or **Conda** (used to install `patchelf`, Node.js, and build tools).
*   **curl** or **wget** (for downloading libraries).
*   Internet access.

## Usage

### `fix_antigravity_server.sh`
Patches Antigravity Server binaries. Requires an explicit execution target.
```bash
# Patch remotely (recommended)
bash fix_antigravity_server.sh <your_ssh_host>

# Patch locally on the server
bash fix_antigravity_server.sh local
```

### `fix_vscode_server.sh`
Patches VS Code Server binaries. Requires an explicit execution target.
```bash
# Patch remotely (recommended)
bash fix_vscode_server.sh <your_ssh_host>

# Patch locally on the server
bash fix_vscode_server.sh local
```

### `reset_server.sh`
Resets both Antigravity Server and VS Code Server installations (kills processes, removes server directories, removes conda environments).
```bash
# Reset remotely
bash reset_server.sh <your_ssh_host>

# Reset locally on the server
bash reset_server.sh
```

## Typical Workflow

### Antigravity Server
1. **Reset** (optional): `bash reset_server.sh <your_ssh_host>`
2. **Download**: Attempt to connect via Antigravity. It will fail, but this downloads the server files.
3. **Patch**: `bash fix_antigravity_server.sh <your_ssh_host>`
4. **Connect**: Connect via Antigravity again.

### VS Code Server
1. **Download**: Attempt to connect via VS Code Remote SSH. It will fail, but this downloads the server files.
2. **Patch**: `bash fix_vscode_server.sh <your_ssh_host>`
3. **Connect**: Connect via VS Code Remote SSH again.

> **Note:** When either server updates, it downloads new binaries that overwrite the patched ones. Re-run the appropriate patch script to fix.
