#!/bin/bash
# build_glibc_source.sh
# Automates the building of GLIBC 2.28 and GCC runtime libraries from source on CentOS 7
# Use this script if you do not want to download the pre-compiled binaries from the GitHub release.

set -e

# Support remote execution via SSH if a hostname is provided
if [ -n "$1" ]; then
    echo "🚀 Connecting to $1 to build glibc from source remotely..."
    ssh "$1" 'bash -s' < "$0"
    if [ $? -eq 0 ]; then
        echo "✅ Source build successfully completed on $1!"
    else
        echo "❌ Failed to build from source on $1."
    fi
    exit $?
fi

LIB_STORE="$HOME/.antigravity-server/lib-glibc-2.28"
BUILD_DIR=$(mktemp -d)

echo "🛠️  Starting source compilation for GLIBC 2.28 and libstdc++..."
echo "⚠️  WARNING: This will take a significant amount of time."

# 1. Install necessary system build tools
echo "📦 Installing prerequisites (requires sudo)..."
sudo yum groupinstall -y "Development Tools"
sudo yum install -y wget bison texinfo python3

cd "$BUILD_DIR"

# 2. Build GLIBC 2.28
echo "⬇️  Downloading GLIBC 2.28 source..."
wget -qO- https://ftp.gnu.org/gnu/glibc/glibc-2.28.tar.gz | tar -xz

mkdir -p build-glibc
cd build-glibc

echo "⚙️  Configuring GLIBC 2.28..."
../glibc-2.28/configure --prefix="$LIB_STORE" --disable-profile --enable-add-ons --with-headers=/usr/include --with-binutils=/usr/bin

echo "🔨 Compiling GLIBC 2.28..."
make -j$(nproc)

echo "📦 Installing GLIBC to $LIB_STORE..."
make install

cd "$BUILD_DIR"

# 3. Build libstdc++ (GCC 8.3.0)
echo "⬇️  Downloading GCC 8.3.0 source for libstdc++..."
wget -qO- https://ftp.gnu.org/gnu/gcc/gcc-8.3.0/gcc-8.3.0.tar.gz | tar -xz

cd gcc-8.3.0
./contrib/download_prerequisites

mkdir -p ../build-gcc
cd ../build-gcc

echo "⚙️  Configuring GCC 8.3.0 (libstdc++ only)..."
../gcc-8.3.0/configure --prefix="$LIB_STORE" --disable-multilib --enable-languages=c,c++

echo "🔨 Compiling libstdc++..."
make -j$(nproc) all-target-libstdc++-v3

echo "📦 Installing libstdc++ to $LIB_STORE..."
make install-target-libstdc++-v3

# 4. Clean up
rm -rf "$BUILD_DIR"

echo "✅ Build complete!"
echo "   The required libraries have been installed to $LIB_STORE."
echo "   You can now run 'bash fix_antigravity_server.sh' without it downloading the external release."
