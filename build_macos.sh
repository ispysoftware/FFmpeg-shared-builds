#!/usr/bin/env bash
# =============================================================================
# build_macos.sh — Build FFmpeg from source on macOS (arm64 or x86_64)
#
# Runs natively on the target arch — no cross-compilation, no Rosetta.
# Mirrors the Dockerfile: all codec deps built statically, baked into the
# FFmpeg .dylib files.  Nothing extra to deploy alongside them.
#
# Hardware acceleration: VideoToolbox + AudioToolbox (Apple native frameworks,
# always available — no driver install required on the target machine).
#
# Usage:
#   ./build_macos.sh                    # uses FFMPEG_VER default (8.1)
#   FFMPEG_VER=8.1 ./build_macos.sh
#   FFMPEG_VER=8.1 JOBS=8 ./build_macos.sh
#
# Output:
#   out/ffmpeg<ver>-macos-arm64.tar.xz    (on Apple Silicon)
#   out/ffmpeg<ver>-macos-x86_64.tar.xz  (on Intel)
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
ARCH=$(uname -m)                        # arm64 or x86_64
JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}

SYSROOT=/tmp/ffmpeg-deps-${ARCH}        # static deps install prefix
FFMPEG_PREFIX=/tmp/ffmpeg-out-${ARCH}   # FFmpeg install prefix
BUILD_DIR=/tmp/ffmpeg-build-${ARCH}     # scratch build space
SCRIPT_DIR="$(cd "$(dirname "$0")"; pwd)"
OUT_DIR="${SCRIPT_DIR}/out"

if [ "$ARCH" = "arm64" ]; then
    ARCHIVE="ffmpeg${FFMPEG_VER}-macos-arm64.tar.xz"
    OPENSSL_TARGET=darwin64-arm64-cc
else
    ARCHIVE="ffmpeg${FFMPEG_VER}-macos-x86_64.tar.xz"
    OPENSSL_TARGET=darwin64-x86_64-cc
fi

echo ""
echo "==> FFmpeg ${FFMPEG_VER} — macOS ${ARCH}"
echo "    sysroot:        ${SYSROOT}"
echo "    ffmpeg prefix:  ${FFMPEG_PREFIX}"
echo "    output:         ${OUT_DIR}/${ARCHIVE}"
echo "    jobs:           ${JOBS}"
echo ""

# ============================================================================
# 1. Build tools
# ============================================================================
echo "==> Installing build tools..."
brew install nasm cmake meson ninja pkg-config automake autoconf libtool yasm

# ============================================================================
# 2. Build environment
# ============================================================================
export CC=clang
export CXX=clang++
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
curl -fsSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" | tar xz
cd zlib-${ZLIB_VER}
CC=${CC} CFLAGS="${CFLAGS}" ./configure --prefix=${SYSROOT} --static
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf zlib-*

# ---------------------------------------------------------------------------
# bzip2
# ---------------------------------------------------------------------------
echo "==> bzip2 ${BZIP2_VER}"
curl -fsSL "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VER}.tar.gz" | tar xz
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
curl -fsSL "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" | tar xz
cd xz-${XZ_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared --disable-doc \
    --disable-lzmadec --disable-lzmainfo --disable-scripts
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf xz-*

# ---------------------------------------------------------------------------
# OpenSSL 3  (https / rtmps)
# ---------------------------------------------------------------------------
echo "==> OpenSSL ${OPENSSL_VER}"
curl -fsSL "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" | tar xz
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
curl -fsSL "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.gz" | tar xz
cd libogg-${OGG_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf libogg-*

# ---------------------------------------------------------------------------
# libvorbis
# ---------------------------------------------------------------------------
echo "==> libvorbis ${VORBIS_VER}"
curl -fsSL "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.gz" | tar xz
cd libvorbis-${VORBIS_VER}
./configure --prefix=${SYSROOT} --with-ogg=${SYSROOT} \
    --enable-static --disable-shared --disable-oggtest
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf libvorbis-*

# ---------------------------------------------------------------------------
# Opus
# ---------------------------------------------------------------------------
echo "==> Opus ${OPUS_VER}"
curl -fsSL "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz" | tar xz
cd opus-${OPUS_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared \
    --disable-doc --disable-extra-programs
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf opus-*

# ---------------------------------------------------------------------------
# libmp3lame
# ---------------------------------------------------------------------------
echo "==> libmp3lame ${LAME_VER}"
curl -fsSL "https://downloads.sourceforge.net/project/lame/lame/${LAME_VER}/lame-${LAME_VER}.tar.gz" | tar xz
cd lame-${LAME_VER}
./configure --prefix=${SYSROOT} --enable-static --disable-shared \
    --disable-gtktest --disable-analyzer-hooks --disable-decoder --disable-frontend
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf lame-*

# ---------------------------------------------------------------------------
# libvpx  (VP8 / VP9)
# nasm is used for x86_64 asm; on arm64 the integrated assembler handles it.
# ---------------------------------------------------------------------------
echo "==> libvpx ${VPX_VER}"
curl -fsSL "https://github.com/webmproject/libvpx/archive/v${VPX_VER}.tar.gz" \
    -o libvpx-${VPX_VER}.tar.gz
tar xf libvpx-${VPX_VER}.tar.gz && cd libvpx-${VPX_VER}
VPX_AS_FLAG=""
if [ "$ARCH" = "x86_64" ]; then VPX_AS_FLAG="--as=nasm"; fi
./configure --prefix=${SYSROOT} \
    --enable-static --disable-shared \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp8 --enable-vp9 --enable-runtime-cpu-detect \
    ${VPX_AS_FLAG}
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf libvpx-*

# ---------------------------------------------------------------------------
# dav1d  (AV1 decoder)
# ---------------------------------------------------------------------------
echo "==> dav1d ${DAV1D_VER}"
curl -fsSL "https://github.com/videolan/dav1d/archive/refs/tags/${DAV1D_VER}.tar.gz" \
    -o dav1d-${DAV1D_VER}.tar.gz
tar xf dav1d-${DAV1D_VER}.tar.gz && cd dav1d-${DAV1D_VER}
meson setup _build \
    --prefix=${SYSROOT} --default-library=static --buildtype=release \
    -Denable_tools=false -Denable_tests=false
ninja -C _build -j${JOBS} && ninja -C _build install
cd "${BUILD_DIR}" && rm -rf dav1d-*

# ---------------------------------------------------------------------------
# libx264  (GPL 2+)
# ---------------------------------------------------------------------------
echo "==> libx264 (${X264_VER})"
curl -fsSL \
    "https://code.videolan.org/videolan/x264/-/archive/${X264_VER}/x264-${X264_VER}.tar.gz" \
    | tar xz
cd x264-*/
X264_AS_FLAG=""
if [ "$ARCH" = "x86_64" ]; then X264_AS_FLAG="AS=nasm"; fi
${X264_AS_FLAG} ./configure --prefix=${SYSROOT} \
    --enable-static --disable-cli --disable-opencl --enable-pic
make -j${JOBS} && make install
cd "${BUILD_DIR}" && rm -rf x264-*

# ============================================================================
# 4. FFmpeg  —  GPL · shared libraries (.dylib)
# ============================================================================
echo ""
echo "==> FFmpeg ${FFMPEG_VER}"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz" | tar xJ
cd ffmpeg-${FFMPEG_VER}

./configure \
    --prefix="${FFMPEG_PREFIX}" \
    \
    --pkg-config=${PKG_CONFIG} \
    --pkg-config-flags="--static" \
    \
    --extra-cflags="${CFLAGS} -I${SYSROOT}/include" \
    --extra-ldflags="-L${SYSROOT}/lib" \
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
