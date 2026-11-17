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

1.  **Install Toolchain**: Creates a conda environment (`vscode-node`) with `gxx_linux-64` (for rebuilding native modules), a modern `wget`, and a fallback Node.js.
2.  **Install Modern wget**: A conda-provided wget wrapper is installed to `~/.local/bin/` (CentOS 7's system wget is too old for VS Code's download scripts).
3.  **Pick a Node per build**: For each server install, reads the Node version VS Code bundles (e.g. `v24.21.0`) and downloads the **same version** built for glibc 2.17 from [unofficial-builds.nodejs.org](https://unofficial-builds.nodejs.org/) (`linux-x64-glibc-217`, SHA256-verified) into `~/.local/share/vscode-node-glibc217/`. If no such build exists, falls back to the conda Node.
4.  **Patch Server Installations**: Backs up the original `node` binary and replaces it with a wrapper pointing to the chosen Node. The wrapper also prepends `~/.local/share/vscode-node-glibc217/lib` (a copy of just `libstdc++.so.6` and `libgcc_s.so.1` from the conda env) to `LD_LIBRARY_PATH`, because VS Code's native modules (`spdlog`, `vsda`, `kerberos`, `@parcel/watcher`...) need `GLIBCXX_3.4.20+`, which CentOS 7's libstdc++ lacks.
5.  **Rebuild node-pty**: If the bundled `pty.node` has missing glibc symbols or fails to load, it is rebuilt from source against the chosen Node's headers.
6.  **Patch vsce-sign**: Wraps the extension-signature binary with the conda `libstdc++` (needs `GLIBCXX_3.4.20+`), otherwise extension installs fail with `Signature verification failed`.
7.  **Configure Codex**: Sets `sandbox_mode = "danger-full-access"` in `~/.codex/config.toml` to bypass `bwrap` (requires unprivileged user namespaces, unavailable on CentOS 7's kernel 3.10).

> **Why not just conda Node?** VS Code 1.141+ (Node 24) imports `registerHooks` from `node:module`, which only exists in Node ≥ 22.15. Every conda-forge `nodejs` ≥ 22.15 is built against glibc 2.28 and refuses to install on CentOS 7, so the newest conda Node (22.6) crashes with `SyntaxError: The requested module 'node:module' does not provide an export named 'registerHooks'`. The unofficial glibc-2.17 builds are the only way to get a matching Node.

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
Every VS Code update downloads a new ~650 MB server build into `~/.vscode-server/bin/` and never removes the old one, so the script **deletes all but the newest build** before patching. Set `KEEP_BUILDS` to change that:
```bash
KEEP_BUILDS=2 bash fix_vscode_server.sh <your_ssh_host>   # keep the 2 newest (e.g. two clients on different VS Code versions)
KEEP_BUILDS=0 bash fix_vscode_server.sh <your_ssh_host>   # never delete anything
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
