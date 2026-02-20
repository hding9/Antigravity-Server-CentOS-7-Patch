# Antigravity Server CentOS 7 Patch

## Overview
This script patches the **Antigravity** (VS Code Server fork) binaries to run on legacy Linux systems like **CentOS 7**, which lack the required `glibc >= 2.28`.

## Acknowledgements & Credits
**Huge thanks to [MikeWang000000/vscode-server-centos7](https://github.com/MikeWang000000/vscode-server-centos7).**

This fix relies entirely on the pre-compiled `glibc` and `gcc` runtime libraries provided by the releases in that repository. Without those artifacts, building the toolchain from source would be required. This project adapts those artifacts specifically for the Antigravity server structure.

## How It Works
It uses a **"Side-Loading & Pure Patching"** strategy:

1.  **Download Dependencies**: The script dynamically fetches the `glibc 2.28` runtime libraries from `MikeWang000000/vscode-server-centos7` releases. Alternatively, you can build them from source using the provided `build_glibc_source.sh` script.
2.  **Extract**: Libraries are saved to `~/.antigravity-server/lib-glibc-2.28`.
3.  **Patch**: It uses `patchelf` to modify the ELF headers of the `node` binary and native extensions.
    *   **Interpreter**: Changed to the side-loaded `ld-linux-x86-64.so.2`.
    *   **RPATH**: Changed to point to the side-loaded library directory.

This approach ensures the server uses the modern libraries **without** altering the global system environment or using wrapper scripts (which can cause terminal crashes).

## Prerequisites
*   **Micromamba** or **Conda** (used to install `patchelf`).
*   Internet access.

## Alternative: Build From Source
If you do not want to download the pre-compiled binaries from the third-party GitHub repository, you can build GLIBC 2.28 and libstdc++ strictly from GNU source code. 

**Note: This takes a significant amount of time.**

Run this script *before* running the patch script:
```bash
# Remotely
bash build_glibc_source.sh <your_ssh_host>

# Or locally on the server
bash build_glibc_source.sh
```
Once complete, the `--download` step in `fix_antigravity_server.sh` will automatically be skipped.

## Usage

### 1. Reset (Recommended)
Clean up any broken previous installations.

**Option A: Reset remotely from your local machine**
```bash
bash reset_server.sh <your_ssh_host>
```

**Option B: Reset directly on the remote server**
```bash
bash reset_server.sh
```

### 2. Download Server
Attempt to connect via VS Code/Antigravity. It will fail, but this downloads the server files to your remote host.

### 3. Apply Patch
When Antigravity updates, its new binaries will overwrite the patched ones, causing the GLIBC error to return. You will need to re-apply the patch.

**Option A: Patch remotely from your local machine (Recommended)**
You can patch the remote server directly from your Mac without needing to manually copy any scripts over. Run this convenience command, replacing `<your_ssh_host>` with your SSH host alias or IP address:
```bash
bash fix_antigravity_server.sh <your_ssh_host>
```

**Option B: Patch directly on the remote server**
If you have already copied the repository to the remote CentOS 7 machine, you can run the patch script directly without any arguments:
```bash
bash fix_antigravity_server.sh
```

### 4. Connect
Connect via Antigravity again. It should now work perfectly.
