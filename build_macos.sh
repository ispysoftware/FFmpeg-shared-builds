#!/usr/bin/env bash
# =============================================================================
# build_macos.sh — Build FFmpeg from source on macOS
#
# Runs natively on arm64 (Apple Silicon).  Can also cross-compile for x86_64
# by setting TARGET_ARCH=x86_64 — used in CI so both architectures can be
# built on a single macos-latest (arm64) runner.
#
# Mirrors the Dockerfile: all codec deps built statically, baked into the
# FFmpeg .dylib files.  Nothing extra to deploy alongside them.
#
# Hardware acceleration: VideoToolbox + AudioToolbox (Apple native frameworks,
# always available — no driver install required on the target machine).
#
# Usage:
#   ./build_macos.sh                              # native arch, FFmpeg 8.1
#   FFMPEG_VER=8.1 ./build_macos.sh
#   TARGET_ARCH=x86_64 ./build_macos.sh           # cross-compile for x86_64
#   FFMPEG_VER=8.1 JOBS=8 ./build_macos.sh
#
# Output:
#   out/ffmpeg<ver>-macos-arm64.tar.xz
#   out/ffmpeg<ver>-macos-x86_64.tar.xz
# =============================================================================

set -euo pipefail

# ============================================================================
# Version pins — keep in sync with Dockerfile ARGs
# ============================================================================
FFMPEG_VER=${FFMPEG_VER:-8.1}
ZLIB_VER=1.3.1
BZIP2_VER=1.0.8
XZ_VER=5.6.2
OPENSSL_VER=3.4.1
OGG_VER=1.3.5
VORBIS_VER=1.3.7
OPUS_VER=1.5.2
LAME_VER=3.100
VPX_VER=1.14.1
DAV1D_VER=1.4.1
X264_VER=stable

# ============================================================================
# Paths
# ============================================================================
ARCH=$(uname -m)                              # native machine arch: arm64 or x86_64
TARGET_ARCH=${TARGET_ARCH:-${ARCH}}           # compile target (may differ for cross-builds)
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}

SYSROOT=/tmp/ffmpeg-deps-${TARGET_ARCH}       # static deps install prefix
FFMPEG_PREFIX=/tmp/ffmpeg-out-${TARGET_ARCH}  # FFmpeg install prefix
BUILD_DIR=/tmp/ffmpeg-build-${TARGET_ARCH}    # scratch build space
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
OUT_DIR="${SCRIPT_DIR}/out"

if [ "$TARGET_ARCH" = "arm64" ]; then
    ARCHIVE="ffmpeg${FFMPEG_VER}-macos-arm64.tar.xz"
    OPENSSL_TARGET=darwin64-arm64-cc
else
    ARCHIVE="ffmpeg${FFMPEG_VER}-macos-x86_64.tar.xz"
    OPENSSL_TARGET=darwin64-x86_64-cc
fi

echo ""
echo "==> FFmpeg ${FFMPEG_VER} — macOS ${TARGET_ARCH}  (host: ${ARCH})"
echo "    sysroot:        ${SYSROOT}"
echo "    ffmpeg prefix:  ${FFMPEG_PREFIX}"
echo "    output:         ${OUT_DIR}/${ARCHIVE}"
echo "    jobs:           ${JOBS}"
echo ""

# ============================================================================
# 1. Build tools
# ============================================================================
echo "==> Installing build tools..."
# Suppress the auto-update that fires on every brew call in CI — it's slow and
# can fail independently of what we're actually trying to install.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew install nasm cmake meson ninja pkg-config automake autoconf libtool yasm

# ============================================================================
# 2. Build environment
# ============================================================================
# Pin the deployment target so FFmpeg's configure doesn't raise
# -Werror=partial-availability against SDK APIs newer than our floor.
if [ "$TARGET_ARCH" = "arm64" ]; then
    export MACOSX_DEPLOYMENT_TARGET=11.0   # first Apple Silicon release
else
    export MACOSX_DEPLOYMENT_TARGET=10.15  # Catalina — reasonable x86_64 floor
fi

# When cross-compiling (TARGET_ARCH != ARCH), embed -arch in CC/CXX so every
# compiler invocation targets the right architecture.  Autotools packages also
# need --host to suppress "cross-compiling" warnings and select correct paths.
if [ "${TARGET_ARCH}" != "${ARCH}" ]; then
    export CC="clang -arch ${TARGET_ARCH}"
    export CXX="clang++ -arch ${TARGET_ARCH}"
    HOST_FLAG="--host=${TARGET_ARCH}-apple-darwin"
else
    export CC=clang
    export CXX=clang++
    HOST_FLAG=""
fi

export AR=ar
export RANLIB=ranlib
export STRIP=strip
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I${SYSROOT}/include"
export LDFLAGS="-L${SYSROOT}/lib"
export PKG_CONFIG=pkg-config
export PKG_CONFIG_PATH="${SYSROOT}/lib/pkgconfig:${SYSROOT}/share/pkgconfig"
# Do NOT set PKG_CONFIG_LIBDIR — on macOS that replaces the default search
# paths entirely and causes Homebrew's pkg-config to miss our sysroot .pc files.

mkdir -p "${SYSROOT}" "${FFMPEG_PREFIX}" "${BUILD_DIR}" "${OUT_DIR}"
cd "${BUILD_DIR}"

# ============================================================================
# 3. Dependencies (all built static — baked into FFmpeg .dylib files)
# ============================================================================

# ---------------------------------------------------------------------------
# zlib
# ---------------------------------------------------------------------------
echo "==> zlib ${ZLIB_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" | tar xz
cd zlib-${ZLIB_VER}
CC=${CC} CFLAGS="${CFLAGS}" ./configure --prefix=${SYSROOT} --static
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf zlib-*

# ---------------------------------------------------------------------------
# bzip2
# ---------------------------------------------------------------------------
echo "==> bzip2 ${BZIP2_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VER}.tar.gz" | tar xz
cd bzip2-${BZIP2_VER}
make -j${JOBS} \
    CC="${CC}" CFLAGS="${CFLAGS} -Wall -Winline -D_FILE_OFFSET_BITS=64" \
    AR="${AR}" RANLIB="${RANLIB}" libbz2.a
install -d ${SYSROOT}/include ${SYSROOT}/lib
install -m 644 bzlib.h  ${SYSROOT}/include/
install -m 644 libbz2.a ${SYSROOT}/lib/
${RANLIB} ${SYSROOT}/lib/libbz2.a
cd "${BUILD_DIR}" && rm -rf bzip2-*

# ---------------------------------------------------------------------------
# xz / liblzma
# ---------------------------------------------------------------------------
echo "==> xz ${XZ_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" | tar xz
cd xz-${XZ_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared --disable-doc \
    --disable-lzmadec --disable-lzmainfo --disable-scripts \
    ${HOST_FLAG}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf xz-*

# ---------------------------------------------------------------------------
# OpenSSL 3  (https / rtmps)
# ---------------------------------------------------------------------------
echo "==> OpenSSL ${OPENSSL_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" | tar xz
cd openssl-${OPENSSL_VER}
./Configure ${OPENSSL_TARGET} \
    --prefix=${SYSROOT} --openssldir=${SYSROOT}/ssl \
    --libdir=lib no-shared no-tests no-apps
make -j${JOBS} && make install_sw
cd "${BUILD_DIR}" && rm -rf openssl-*

# ---------------------------------------------------------------------------
# libogg
# ---------------------------------------------------------------------------
echo "==> libogg ${OGG_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.gz" | tar xz
cd libogg-${OGG_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared \
    ${HOST_FLAG}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf libogg-*

# ---------------------------------------------------------------------------
# libvorbis
# ---------------------------------------------------------------------------
echo "==> libvorbis ${VORBIS_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.gz" | tar xz
cd libvorbis-${VORBIS_VER}
# -force_cpusubtype_ALL is a PowerPC-era linker flag removed in Xcode 15+.
# It is hardcoded in libvorbis's bundled configure script for Darwin targets.
# Patch it out before running configure (no autoreconf needed).
sed -i '' 's/-force_cpusubtype_ALL//g' configure
./configure --prefix=${SYSROOT} --with-ogg=${SYSROOT} \
    --enable-static --disable-shared --disable-oggtest \
    ${HOST_FLAG}
make -j${JOBS}
make install
cd "${BUILD_DIR}" && rm -rf libvorbis-*

# ---------------------------------------------------------------------------
# Opus
# ---------------------------------------------------------------------------
echo "==> Opus ${OPUS_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz" | tar xz
cd opus-${OPUS_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared \
    --disable-doc --disable-extra-programs \
    ${HOST_FLAG}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf opus-*

# ---------------------------------------------------------------------------
# libmp3lame
# ---------------------------------------------------------------------------
echo "==> libmp3lame ${LAME_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://downloads.sourceforge.net/project/lame/lame/${LAME_VER}/lame-${LAME_VER}.tar.gz" | tar xz
cd lame-${LAME_VER}
# Same -force_cpusubtype_ALL issue as libvorbis — patch the bundled configure.
sed -i '' 's/-force_cpusubtype_ALL//g' configure
./configure --prefix=${SYSROOT} --enable-static --disable-shared \
    --disable-gtktest --disable-analyzer-hooks --disable-decoder --disable-frontend \
    ${HOST_FLAG}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf lame-*

# ---------------------------------------------------------------------------
# libvpx  (VP8 / VP9)
# nasm is used for x86_64 asm; on arm64 the integrated assembler handles it.
# ---------------------------------------------------------------------------
echo "==> libvpx ${VPX_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://github.com/webmproject/libvpx/archive/v${VPX_VER}.tar.gz" \
    -o libvpx-${VPX_VER}.tar.gz
tar xf libvpx-${VPX_VER}.tar.gz && cd libvpx-${VPX_VER}
# Derive the darwin kernel major version and cap at the highest target that
# libvpx 1.14.1 knows about (darwin23 = macOS 14).  The generic
# "arm64-darwin-gcc" target is the iOS target — the numbered ones are macOS.
DARWIN_MAJOR=$(uname -r | cut -d. -f1)
[ "${DARWIN_MAJOR}" -gt 23 ] && DARWIN_MAJOR=23
if [ "$TARGET_ARCH" = "arm64" ]; then
    VPX_TARGET="arm64-darwin${DARWIN_MAJOR}-gcc"
else
    VPX_TARGET="x86_64-darwin${DARWIN_MAJOR}-gcc"
    VPX_AS_EXTRA="--as=nasm"
fi
./configure --prefix=${SYSROOT} \
    --target=${VPX_TARGET} \
    --enable-static --disable-shared \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp8 --enable-vp9 --enable-runtime-cpu-detect \
    ${VPX_AS_EXTRA:-}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf libvpx-*

# ---------------------------------------------------------------------------
# dav1d  (AV1 decoder)
# ---------------------------------------------------------------------------
echo "==> dav1d ${DAV1D_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://github.com/videolan/dav1d/archive/refs/tags/${DAV1D_VER}.tar.gz" \
    -o dav1d-${DAV1D_VER}.tar.gz
tar xf dav1d-${DAV1D_VER}.tar.gz && cd dav1d-${DAV1D_VER}
if [ "${TARGET_ARCH}" != "${ARCH}" ]; then
    # Meson needs a cross-file to know we're targeting a different architecture.
    DAV1D_CROSS="${BUILD_DIR}/dav1d-cross.ini"
    if [ "${TARGET_ARCH}" = "arm64" ]; then
        DAV1D_CPU_FAMILY="aarch64"
    else
        DAV1D_CPU_FAMILY="x86_64"
    fi
    cat > "${DAV1D_CROSS}" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
[properties]
c_args = ['-arch', '${TARGET_ARCH}']
cpp_args = ['-arch', '${TARGET_ARCH}']
c_link_args = ['-arch', '${TARGET_ARCH}']
cpp_link_args = ['-arch', '${TARGET_ARCH}']
[host_machine]
system = 'darwin'
cpu_family = '${DAV1D_CPU_FAMILY}'
cpu = '${TARGET_ARCH}'
endian = 'little'
EOF
    meson setup _build \
        --prefix=${SYSROOT} --default-library=static --buildtype=release \
        --cross-file "${DAV1D_CROSS}" \
        -Denable_tools=false -Denable_tests=false
else
    meson setup _build \
        --prefix=${SYSROOT} --default-library=static --buildtype=release \
        -Denable_tools=false -Denable_tests=false
fi
ninja -C _build -j${JOBS} && ninja -C _build install
cd "${BUILD_DIR}" && rm -rf dav1d-*

# ---------------------------------------------------------------------------
# libx264  (GPL 2+)
# ---------------------------------------------------------------------------
echo "==> libx264 (${X264_VER})"
curl -fsSL --retry 3 --retry-delay 5 \
    "https://code.videolan.org/videolan/x264/-/archive/${X264_VER}/x264-${X264_VER}.tar.gz" \
    | tar xz
cd x264-*/
if [ "$TARGET_ARCH" = "x86_64" ]; then
    ./configure --prefix=${SYSROOT} \
        --enable-static --disable-cli --disable-opencl --enable-pic \
        ${HOST_FLAG} \
        AS=nasm
else
    ./configure --prefix=${SYSROOT} \
        --enable-static --disable-cli --disable-opencl --enable-pic \
        ${HOST_FLAG}
fi
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf x264-*

# ============================================================================
# 4. FFmpeg  —  GPL · shared libraries (.dylib)
# ============================================================================
# ============================================================================
# Sanity-check: verify all dep .pc files are in place before FFmpeg configure.
# A missing file here means a dep build failed silently despite set -e.
# ============================================================================
echo ""
echo "==> Verifying dependency pkg-config files..."
# mp3lame is NOT listed here: lame's autotools doesn't reliably install mp3lame.pc
# on all platforms, and FFmpeg finds it via direct header/library probe instead.
for pc in libssl vorbis opus vpx dav1d x264; do
    if ! PKG_CONFIG_PATH="${PKG_CONFIG_PATH}" pkg-config --exists "${pc}" 2>/dev/null; then
        echo "ERROR: pkg-config package '${pc}' not found — dep build failed"
        echo "  lib/pkgconfig:"
        ls "${SYSROOT}/lib/pkgconfig/" 2>/dev/null || echo "    (directory does not exist)"
        echo "  share/pkgconfig:"
        ls "${SYSROOT}/share/pkgconfig/" 2>/dev/null || echo "    (directory does not exist)"
        exit 1
    fi
done
echo "    All deps present."

# ============================================================================
# FFmpeg cross-compilation flags.
# --cc/--cxx must be plain compiler names; -arch goes via extra-cflags/ldflags
# so that every configure link test (e.g. dav1d feature check) targets the
# right architecture.  Without -arch in extra-ldflags the test object would be
# compiled as x86_64 but linked as arm64, making all cross-dep checks fail.
if [ "${TARGET_ARCH}" != "${ARCH}" ]; then
    FFMPEG_CROSS_FLAGS="--enable-cross-compile --target-os=darwin"
    FFMPEG_ARCH_CFLAGS="-arch ${TARGET_ARCH}"
    FFMPEG_ARCH_LDFLAGS="-arch ${TARGET_ARCH}"
else
    FFMPEG_CROSS_FLAGS=""
    FFMPEG_ARCH_CFLAGS=""
    FFMPEG_ARCH_LDFLAGS=""
fi

echo ""
echo "==> FFmpeg ${FFMPEG_VER}"
curl -fsSL --retry 3 --retry-delay 5 "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz" | tar xJ
cd ffmpeg-${FFMPEG_VER}

./configure \
    --prefix="${FFMPEG_PREFIX}" \
    \
    --pkg-config=${PKG_CONFIG} \
    --pkg-config-flags="--static" \
    \
    --arch=${TARGET_ARCH} \
    --cc=clang \
    --cxx=clang++ \
    ${FFMPEG_CROSS_FLAGS} \
    --extra-cflags="${CFLAGS} ${FFMPEG_ARCH_CFLAGS} -I${SYSROOT}/include" \
    --extra-ldflags="-L${SYSROOT}/lib ${FFMPEG_ARCH_LDFLAGS}" \
    --extra-libs="-lpthread -lm" \
    \
    --enable-shared \
    --disable-static \
    \
    --enable-gpl \
    --enable-version3 \
    --disable-nonfree \
    \
    --disable-debug \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    \
    --enable-zlib \
    --enable-bzlib \
    --enable-lzma \
    --enable-openssl \
    \
    --enable-libx264 \
    --enable-libopus \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libmp3lame \
    --enable-libdav1d \
    \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    \
    --disable-ffplay \
    --disable-ffprobe \
    || { echo "=== ffmpeg configure failed ===";
         [ -f ffbuild/config.log ] && tail -100 ffbuild/config.log;
         exit 1; }

make -j${JOBS} && make install

# Strip
${STRIP} "${FFMPEG_PREFIX}/bin/ffmpeg"
find "${FFMPEG_PREFIX}/lib" -name '*.dylib' -not -type l \
    -exec ${STRIP} -x {} \;

cd "${BUILD_DIR}" && rm -rf ffmpeg-*

# ============================================================================
# 5. Fix dylib install names and rpaths
#
# After 'make install', each .dylib has an absolute install name pointing at
# ${FFMPEG_PREFIX}/lib/libav*.dylib.  We rewrite them to @rpath/<name> so the
# libraries are relocatable — FFmpeg.AutoGen (and any other consumer) can load
# them from wherever they're deployed by adding the lib directory to the rpath.
# ============================================================================
echo ""
echo "==> Fixing dylib install names..."
FFLIB="${FFMPEG_PREFIX}/lib"
FFBIN="${FFMPEG_PREFIX}/bin/ffmpeg"

# Process real files only (not symlinks)
for dylib in "${FFLIB}"/*.dylib; do
    [ -L "$dylib" ] && continue
    libname=$(basename "$dylib")

    # Update this library's own install name
    install_name_tool -id "@rpath/${libname}" "$dylib"

    # Rewrite references to other FFmpeg libs within this library
    while IFS= read -r ref; do
        case "$ref" in
            "${FFLIB}"/*)
                install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$dylib"
                ;;
        esac
    done < <(otool -L "$dylib" | awk 'NR>1 {print $1}')
done

# Fix the ffmpeg CLI binary
install_name_tool -add_rpath "@executable_path/../lib" "${FFBIN}"
while IFS= read -r ref; do
    case "$ref" in
        "${FFLIB}"/*)
            install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "${FFBIN}"
            ;;
    esac
done < <(otool -L "${FFBIN}" | awk 'NR>1 {print $1}')

# ============================================================================
# 6. Package
# ============================================================================
echo ""
echo "==> Packaging ${ARCHIVE}..."
tar -cJf "${OUT_DIR}/${ARCHIVE}" -C "${FFMPEG_PREFIX}" .
SIZE=$(du -sh "${OUT_DIR}/${ARCHIVE}" | cut -f1)
echo ""
echo "==> Done: ${OUT_DIR}/${ARCHIVE}  (${SIZE})"
echo ""
