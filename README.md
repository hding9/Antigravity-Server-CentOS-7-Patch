# Antigravity Server CentOS 7 Patch

## Overview
A collection of scripts that patch **Antigravity** (VS Code Server fork) and **VS Code Remote SSH** server binaries to run on legacy Linux systems like **CentOS 7**, which lack the required `glibc >= 2.28`.

Two separate patching strategies are provided because of CentOS 7's constraints:

| Script | Target | Strategy | Why |
|---|---|---|---|
| `fix_antigravity_server.sh` | Antigravity Server | Side-load glibc 2.28 via `patchelf` | Antigravity ships its own node; patching ELF headers is sufficient |
| `fix_vscode_server.sh` | VS Code Remote SSH | Replace node with conda-installed wrapper | CentOS 7 kernel (3.10) is too old for modern glibc, so a compatible node must be used instead |

## Acknowledgements & Credits
**Huge thanks to [MikeWang000000/vscode-server-centos7](https://github.com/MikeWang000000/vscode-server-centos7).**

The Antigravity fix uses the pre-compiled `glibc` and `gcc` runtime libraries provided by the releases in that repository. Alternatively, you can build them from source using the provided `build_glibc_source.sh` script.

## How It Works

### Antigravity Server (`fix_antigravity_server.sh`)
Uses a **"Side-Loading & Pure Patching"** strategy:

1.  **Fetch Latest Version**: Dynamically detects the latest library release from `MikeWang000000/vscode-server-centos7` using multiple fallback methods (curl redirects, wget, git ls-remote, GitHub API, HTML scraping).
2.  **Download & Extract**: `glibc 2.28` runtime libraries are saved to `~/.antigravity-server/lib-glibc-2.28`.
3.  **Patch**: Uses `patchelf` to modify ELF headers of all server binaries and native `.node` modules:
    *   **Interpreter**: Changed to the side-loaded `ld-linux-x86-64.so.2`.
    *   **RPATH**: Changed to point to the side-loaded library directory.
4.  **Cleanup**: Removes any leftover wrapper scripts from previous patching strategies.

This approach ensures the server uses the modern libraries **without** altering the global system environment or using wrapper scripts (which can cause terminal crashes).

### VS Code Remote SSH (`fix_vscode_server.sh`)
Uses a **"Node Replacement"** strategy:

The `patchelf` approach does not work for VS Code Remote SSH because CentOS 7's kernel (3.10) is too old for modern glibc (which requires kernel 3.17+). Instead, this script:

1.  **Install Compatible Node**: Creates a conda environment (`vscode-node`) with a Node.js build that works on CentOS 7's kernel.
2.  **Install Build Tools**: Installs `gxx_linux-64` from conda-forge for rebuilding native modules (CentOS 7's GCC 4.8.5 lacks C++17 support).
3.  **Install Modern wget**: CentOS 7's system wget is too old for VS Code's download scripts; a conda-provided wget wrapper is installed to `~/.local/bin/`.
4.  **Patch Server Installations**: For each VS Code Server commit directory in `~/.vscode-server/bin/`, backs up the original `node` binary and replaces it with a wrapper script pointing to the conda node.
5.  **Rebuild node-pty**: If the bundled `pty.node` native module has glibc dependency issues, it is rebuilt from source using the conda toolchain.
6.  **Configure Codex**: Sets `sandbox_mode = "danger-full-access"` in `~/.codex/config.toml` to bypass `bwrap`, which fails on CentOS 7's kernel without unprivileged user namespace support.

## Prerequisites
*   **Micromamba** or **Conda** (used to install `patchelf`, Node.js, and build tools).
*   Internet access.

## Scripts

### `fix_antigravity_server.sh`
Patches Antigravity server binaries. Requires an explicit execution target.
```bash
# Patch remotely (recommended)
bash fix_antigravity_server.sh <your_ssh_host>

# Patch locally on the server
bash fix_antigravity_server.sh local
```

### `fix_vscode_server.sh`
Patches VS Code Remote SSH server. Requires an explicit execution target.
```bash
# Patch remotely (recommended)
bash fix_vscode_server.sh <your_ssh_host>

# Patch locally on the server
bash fix_vscode_server.sh local
```

### `reset_server.sh`
Resets the Antigravity server installation (kills processes, removes `~/.antigravity-server`, removes the `antigravity-node` conda environment).
```bash
# Reset remotely
bash reset_server.sh <your_ssh_host>

# Reset locally on the server
bash reset_server.sh
```

### `build_glibc_source.sh`
Builds glibc 2.28 and libstdc++ (GCC 8.3.0) from GNU source code as an alternative to downloading pre-compiled binaries. **This takes a significant amount of time.**
```bash
# Build remotely
bash build_glibc_source.sh <your_ssh_host>

# Build locally on the server
bash build_glibc_source.sh
```
Once complete, `fix_antigravity_server.sh` will detect the libraries and skip the download step.

## Typical Workflow

### Antigravity Server
1. **Reset** (optional): `bash reset_server.sh <your_ssh_host>`
2. **Download**: Attempt to connect via Antigravity. It will fail, but this downloads the server files.
3. **Patch**: `bash fix_antigravity_server.sh <your_ssh_host>`
4. **Connect**: Connect via Antigravity again.

### VS Code Remote SSH
1. **Download**: Attempt to connect via VS Code Remote SSH. It will fail, but this downloads the server files.
2. **Patch**: `bash fix_vscode_server.sh <your_ssh_host>`
3. **Connect**: Connect via VS Code Remote SSH again.

> **Note:** When either server updates, it downloads new binaries that overwrite the patched ones. Re-run the appropriate patch script to fix.
