# Antigravity Server CentOS 7 Patch

## Overview
This script patches the **Antigravity** (VS Code Server fork) binaries to run on legacy Linux systems like **CentOS 7**, which lack the required `glibc >= 2.28`.

## Acknowledgements & Credits
**Huge thanks to [MikeWang000000/vscode-server-centos7](https://github.com/MikeWang000000/vscode-server-centos7).**

This fix relies entirely on the pre-compiled `glibc` and `gcc` runtime libraries provided by the releases in that repository. Without those artifacts, building the toolchain from source would be required. This project adapts those artifacts specifically for the Antigravity server structure.

## How It Works
It uses a **"Side-Loading & Pure Patching"** strategy:

1.  **Download**: The script fetches the `glibc 2.28` runtime libraries from `MikeWang000000/vscode-server-centos7` releases.
2.  **Extract**: Libraries are saved to `~/.antigravity-server/lib-glibc-2.28`.
3.  **Patch**: It uses `patchelf` to modify the ELF headers of the `node` binary and native extensions.
    *   **Interpreter**: Changed to the side-loaded `ld-linux-x86-64.so.2`.
    *   **RPATH**: Changed to point to the side-loaded library directory.

This approach ensures the server uses the modern libraries **without** altering the global system environment or using wrapper scripts (which can cause terminal crashes).

## Prerequisites
*   **Micromamba** or **Conda** (used to install `patchelf`).
*   Internet access.

## Usage

### 1. Reset (Recommended)
Clean up any broken previous installations:
```bash
./reset_server.sh
```

### 2. Download Server
Attempt to connect via VS Code/Antigravity. It will fail, but this downloads the server files.

### 3. Apply Patch
Run the fix script:
```bash
./fix_antigravity_server.sh
```

### 4. Connect
Connect again. It should now work perfectly.
