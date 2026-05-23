# syntax=docker/dockerfile:1
#
# FFmpeg cross-build  ·  armhf / arm64 / x86_64 / rockchip  ·  glibc ≥ 2.28
# Variant : GPL  ·  shared libraries (.so)
#
# ── Targets ──────────────────────────────────────────────────────────────────
#   armhf   Raspberry Pi 2/3/4/Zero2  (ARMv7-A + NEON, hard-float ABI)
#   arm64   Raspberry Pi 3/4/5 64-bit, Rockchip RK3566/RK3568/RK3588, Jetson,
#           and any other aarch64 Linux board
#   x86_64  Linux desktop/server
#
# ── Build ────────────────────────────────────────────────────────────────────
#   docker build --build-arg TARGET=armhf  -t ffmpeg-armhf-build  .
#   docker build --build-arg TARGET=arm64  -t ffmpeg-arm64-build  .
#   docker build --build-arg TARGET=x86_64 -t ffmpeg-x86_64-build .
#
# ── Hardware acceleration per target ─────────────────────────────────────────
#   armhf   V4L2 M2M  (Pi 4/5 H.264 hw decode via kernel driver)
#   arm64   V4L2 M2M  ·  Rockchip MPP (RK VPU, ignored on non-RK boards)
#           NVENC/NVDEC (Jetson)  ·  Vulkan (Mali, VideoCore VII)
#   x86_64  VA-API (Intel/AMD)  ·  NVENC/NVDEC (NVIDIA)  ·  Vulkan  ·  AMF (AMD)
#
# ── Licence note ─────────────────────────────────────────────────────────────
#   --enable-gpl  → GPL 2+ build (required for libx264).
#   Included third-party libs and their licences:
#     libx264     GPL 2+
#     libopus     BSD / RFC-6716
#     libvorbis   BSD
#     libmp3lame  LGPL 2
#     libvpx      BSD   (VP8/VP9 encoder/decoder)
#     dav1d       BSD   (AV1 decoder)
#     OpenSSL 3   Apache 2.0  (https / rtmps)
#     rockchip_mpp  Apache 2.0  (rockchip target only)

# ============================================================================
# Version pins – bump here only
# ============================================================================
ARG FFMPEG_VER=8.1
ARG NASM_VER=2.16.03
ARG ZLIB_VER=1.3.1
ARG BZIP2_VER=1.0.8
ARG XZ_VER=5.6.2
ARG OPENSSL_VER=3.4.1
ARG OGG_VER=1.3.5
ARG VORBIS_VER=1.3.7
ARG OPUS_VER=1.5.2
ARG LAME_VER=3.100
ARG VPX_VER=1.14.1
ARG DAV1D_VER=1.4.1
ARG X264_VER=stable
ARG FFNVCODEC_VER=n12.2.72.0
ARG VULKAN_VER=1.3.296
ARG AMF_VER=1.5.2
ARG LIBDRM_VER=2.4.120
# MPP is cloned from nyanmisaka/rk-mirrors (jellyfin-mpp-next branch) — no tarball version

# ── Target: armhf | arm64 | x86_64
ARG TARGET=armhf

# ============================================================================
# Builder
# ============================================================================
FROM debian:buster AS builder

ARG FFMPEG_VER NASM_VER ZLIB_VER BZIP2_VER XZ_VER OPENSSL_VER
ARG OGG_VER VORBIS_VER OPUS_VER LAME_VER VPX_VER DAV1D_VER X264_VER
ARG FFNVCODEC_VER VULKAN_VER AMF_VER LIBDRM_VER
ARG TARGET

ENV DEBIAN_FRONTEND=noninteractive
ENV SYSROOT=/opt/x-sysroot
ENV FFMPEG_PREFIX=/opt/ffmpeg

# ---------------------------------------------------------------------------
# 0. Fix apt sources — Buster (Debian 10) reached EOL June 2024 and moved to
#    the archive mirror. The archived Release files also have expired Valid-Until
#    dates, so we disable that check. Safe for a build container.
# ---------------------------------------------------------------------------
RUN printf 'deb http://archive.debian.org/debian buster main\ndeb http://archive.debian.org/debian-security buster/updates main\n' \
      > /etc/apt/sources.list \
 && printf 'Acquire::Check-Valid-Until "false";\n' \
      > /etc/apt/apt.conf.d/99no-check-valid-until

# ---------------------------------------------------------------------------
# 1. Toolchains & build utilities
#    All cross-compilers installed in one layer, shared across TARGET variants.
# ---------------------------------------------------------------------------
RUN dpkg --add-architecture armhf \
 && dpkg --add-architecture arm64 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      # ARM 32-bit cross-compiler
      gcc-arm-linux-gnueabihf \
      g++-arm-linux-gnueabihf \
      binutils-arm-linux-gnueabihf \
      # ARM 64-bit cross-compiler (also used for rockchip)
      gcc-aarch64-linux-gnu \
      g++-aarch64-linux-gnu \
      binutils-aarch64-linux-gnu \
      # Native x86_64
      gcc \
      g++ \
      binutils \
      # Windows cross-compiler (win64 target) — MinGW-w64 includes Windows SDK headers
      # for D3D11VA / DXVA2 so no separate SDK download is needed.
      mingw-w64 \
      # Build systems
      cmake \
      make \
      autoconf \
      automake \
      libtool \
      nasm \
      yasm \
      pkg-config \
      # Python + pip — meson/ninja installed via pip below (Buster's packaged
      # meson 0.49 is too old; dav1d and libdrm require meson >= 0.56)
      python3 \
      python3-pip \
      # Kernel headers for V4L2 M2M — multiarch, coexist safely
      linux-libc-dev \
      linux-libc-dev:armhf \
      linux-libc-dev:arm64 \
      # VA-API headers (x86_64 Intel/AMD hardware decode)
      libva-dev \
      # Vulkan runtime .so for linking — headers come from KhronosGroup GitHub
      # (Debian buster/bullseye ship 1.x which is below FFmpeg 8.1's 1.3.277 minimum)
      libvulkan1 \
      libvulkan1:arm64 \
      # Fetch & unpack
      wget \
      git \
      ca-certificates \
      xz-utils \
      bzip2 \
      # Misc
      patch \
      texinfo \
      gettext \
 && rm -rf /var/lib/apt/lists/* \
 && pip3 install --upgrade pip \
 && pip3 install meson ninja

# ---------------------------------------------------------------------------
# 2. Per-target environment
#    Writes /env.sh (sourced by every subsequent RUN step) and
#    /etc/meson/cross.ini (used by dav1d and libdrm on cross-compile targets).
# ---------------------------------------------------------------------------
RUN <<'SETUP'
set -e
mkdir -p /opt/x-sysroot /opt/ffmpeg /etc/meson

case "$TARGET" in
  armhf)
    TRIPLE=arm-linux-gnueabihf
    ARCH_CFLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
    OPENSSL_TARGET=linux-armv4
    VPX_TARGET=armv7-linux-gcc
    FF_ARCH="--arch=arm --cpu=armv7-a"
    FF_EXTRA="--enable-neon --enable-vfp --enable-armv6t2"
    FF_HW="--enable-v4l2_m2m"
    FF_OS=linux ; FF_WIN_FLAGS=""
    EXTRA_LIBS="-lpthread -lm -latomic"
    HARDENING_FLAGS="-fstack-protector-strong"
    MESON_CPU_FAMILY=arm ; MESON_CPU=armv7 ; MESON_SYSTEM=linux
    IS_CROSS=1 ; BUILD_TARGET=armhf
    ;;
  arm64)
    # Covers Pi 3/4/5, Rockchip RK3xxx, Jetson, and generic aarch64.
    # Rockchip MPP is included — on non-Rockchip boards FFmpeg simply won't
    # find the kernel driver at runtime and falls back to software.
    TRIPLE=aarch64-linux-gnu
    ARCH_CFLAGS="-march=armv8-a"
    OPENSSL_TARGET=linux-aarch64
    VPX_TARGET=arm64-linux-gcc
    FF_ARCH="--arch=aarch64"
    FF_EXTRA="--enable-neon"
    FF_HW="--enable-v4l2_m2m --enable-rkmpp --enable-libdrm --enable-vulkan --enable-nvenc --enable-nvdec"
    FF_OS=linux ; FF_WIN_FLAGS=""
    EXTRA_LIBS="-lpthread -lm"
    HARDENING_FLAGS="-fstack-protector-strong"
    MESON_CPU_FAMILY=aarch64 ; MESON_CPU=aarch64 ; MESON_SYSTEM=linux
    IS_CROSS=1 ; BUILD_TARGET=arm64
    ;;
  x86_64)
    TRIPLE=x86_64-linux-gnu
    ARCH_CFLAGS="-march=x86-64"
    OPENSSL_TARGET=linux-x86_64
    VPX_TARGET=x86_64-linux-gcc
    FF_ARCH="--arch=x86_64"
    FF_EXTRA=""
    FF_HW="--enable-vaapi --enable-nvenc --enable-nvdec --enable-vulkan --enable-amf"
    FF_OS=linux ; FF_WIN_FLAGS=""
    EXTRA_LIBS="-lpthread -lm"
    HARDENING_FLAGS="-fstack-protector-strong"
    MESON_CPU_FAMILY=x86_64 ; MESON_CPU=x86_64 ; MESON_SYSTEM=linux
    IS_CROSS=0 ; BUILD_TARGET=x86_64
    ;;
  win64)
    # Windows x86-64 via MinGW-w64 cross-compiler.
    # Produces .dll files loadable by FFmpeg.AutoGen on Windows.
    # D3D11VA and DXVA2 use Windows SDK headers bundled with MinGW-w64.
    # NVENC/NVDEC and AMF are header-only; drivers loaded at runtime.
    TRIPLE=x86_64-w64-mingw32
    ARCH_CFLAGS="-march=x86-64"
    OPENSSL_TARGET=mingw64
    VPX_TARGET=x86_64-win64-gcc
    FF_ARCH="--arch=x86_64"
    FF_EXTRA=""
    FF_HW="--enable-d3d11va --enable-dxva2 --enable-nvenc --enable-nvdec --enable-amf"
    FF_OS=mingw32
    FF_WIN_FLAGS="--enable-w32threads --windres=${TRIPLE}-windres"
    EXTRA_LIBS=""
    # -fstack-protector-strong on MinGW requires libssp for __stack_chk_fail/__stack_chk_guard.
    # Omit it for the win64 cross-build so statically-linked deps (dav1d etc.) don't
    # pull in an SSP runtime dependency that breaks FFmpeg's configure link tests.
    HARDENING_FLAGS=""
    MESON_CPU_FAMILY=x86_64 ; MESON_CPU=x86_64 ; MESON_SYSTEM=windows
    IS_CROSS=1 ; BUILD_TARGET=win64
    ;;
  *)
    echo "ERROR: Unknown TARGET='$TARGET'. Valid: armhf, arm64, x86_64, win64" >&2
    exit 1
    ;;
esac

if [ "$IS_CROSS" = "1" ]; then
  CC_VAL="${TRIPLE}-gcc"   ; CXX_VAL="${TRIPLE}-g++"
  AR_VAL="${TRIPLE}-ar"    ; AS_VAL="${TRIPLE}-as"
  LD_VAL="${TRIPLE}-ld"    ; NM_VAL="${TRIPLE}-nm"
  STRIP_VAL="${TRIPLE}-strip" ; RANLIB_VAL="${TRIPLE}-ranlib"
  OBJCOPY_VAL="${TRIPLE}-objcopy"
  PKG_CFG="/usr/local/bin/${TRIPLE}-pkg-config"
  PKG_PATH="/opt/x-sysroot/lib/pkgconfig:/opt/x-sysroot/share/pkgconfig"
  HOST_FLAG="--host=${TRIPLE}"
  # pkg-config wrapper that resolves our sysroot
  printf '#!/bin/sh\nexec pkg-config "$@"\n' \
    > "/usr/local/bin/${TRIPLE}-pkg-config"
  chmod +x "/usr/local/bin/${TRIPLE}-pkg-config"
  # Meson cross-file (used by dav1d and libdrm)
  cat > /etc/meson/cross.ini <<MESON
[binaries]
c         = '${TRIPLE}-gcc'
cpp       = '${TRIPLE}-g++'
ar        = '${TRIPLE}-ar'
strip     = '${TRIPLE}-strip'
nasm      = 'nasm'
pkgconfig = '${PKG_CFG}'

[host_machine]
system     = '${MESON_SYSTEM}'
cpu_family = '${MESON_CPU_FAMILY}'
cpu        = '${MESON_CPU}'
endian     = 'little'
MESON
else
  CC_VAL=gcc ; CXX_VAL=g++ ; AR_VAL=ar ; AS_VAL=as ; LD_VAL=ld
  NM_VAL=nm  ; STRIP_VAL=strip ; RANLIB_VAL=ranlib ; OBJCOPY_VAL=objcopy
  PKG_CFG=pkg-config
  HOST_FLAG=""
  # Include system paths so FFmpeg configure finds libva and other system libs
  PKG_PATH="/opt/x-sysroot/lib/pkgconfig:/opt/x-sysroot/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
fi

cat > /env.sh <<ENV
export BUILD_TARGET="${BUILD_TARGET}"
export TARGET_TRIPLE="${TRIPLE}"
export IS_CROSS="${IS_CROSS}"
export CC="${CC_VAL}"
export CXX="${CXX_VAL}"
export AR="${AR_VAL}"
export AS="${AS_VAL}"
export LD="${LD_VAL}"
export NM="${NM_VAL}"
export STRIP="${STRIP_VAL}"
export RANLIB="${RANLIB_VAL}"
export OBJCOPY="${OBJCOPY_VAL}"
export CFLAGS="${ARCH_CFLAGS} -O2 -pipe -fPIC ${HARDENING_FLAGS}"
export CXXFLAGS="${ARCH_CFLAGS} -O2 -pipe -fPIC ${HARDENING_FLAGS}"
export CPPFLAGS="-I/opt/x-sysroot/include"
export LDFLAGS="-L/opt/x-sysroot/lib"
export PKG_CONFIG="${PKG_CFG}"
export PKG_CONFIG_PATH="${PKG_PATH}"
export PKG_CONFIG_LIBDIR="${PKG_PATH}"
export OPENSSL_TARGET="${OPENSSL_TARGET}"
export VPX_TARGET="${VPX_TARGET}"
export FF_ARCH_FLAGS="${FF_ARCH}"
export FF_EXTRA_FLAGS="${FF_EXTRA}"
export FF_HW_FLAGS="${FF_HW}"
export FF_OS="${FF_OS}"
export FF_WIN_FLAGS="${FF_WIN_FLAGS}"
export EXTRA_LIBS="${EXTRA_LIBS}"
export HOST_FLAG="${HOST_FLAG}"
ENV

chmod +x /env.sh
SETUP

WORKDIR /build

# ---------------------------------------------------------------------------
# MinGW-w64 shim headers  (win64 only)
# Buster ships MinGW-w64 6.0 which is missing timeapi.h (added in 7.0).
# FFmpeg 8.1's vsrc_amf.c / vf_vpp_amf.c include it directly.
# A stub that re-exports mmsystem.h (which has all the same declarations)
# is the correct fix — identical to what MinGW-w64 7.0+ ships.
# ---------------------------------------------------------------------------
RUN if [ "$TARGET" = "win64" ]; then \
      printf '#ifndef _TIMEAPI_H_\n#define _TIMEAPI_H_\n#include <mmsystem.h>\n#endif /* _TIMEAPI_H_ */\n' \
        > /usr/x86_64-w64-mingw32/include/timeapi.h; \
    fi

# ============================================================================
# Third-party dependencies (static, baked into FFmpeg .so files)
# ============================================================================

# ---------------------------------------------------------------------------
# NASM  (build from source — Buster ships 2.14.02 which is too old for
#        FFmpeg 8.1's new libswscale/x86/ops_float.asm AVX macros; 2.15+ required)
# /usr/local/bin/nasm shadows /usr/bin/nasm via PATH order.
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VER}/nasm-${NASM_VER}.tar.xz" \
 && tar xf nasm-${NASM_VER}.tar.xz && cd nasm-${NASM_VER} \
 && ./configure --prefix=/usr/local \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf nasm-* \
 && nasm --version

# ---------------------------------------------------------------------------
# zlib
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" \
 && tar xf zlib-${ZLIB_VER}.tar.gz && cd zlib-${ZLIB_VER} \
 && CHOST=${TARGET_TRIPLE} CC=${CC} CFLAGS="${CFLAGS}" \
    ./configure --prefix=${SYSROOT} --static \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf zlib-*

# ---------------------------------------------------------------------------
# bzip2
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VER}.tar.gz" \
 && tar xf bzip2-${BZIP2_VER}.tar.gz && cd bzip2-${BZIP2_VER} \
 && make -j$(nproc) \
      CC="${CC}" \
      CFLAGS="${CFLAGS} -Wall -Winline -D_FILE_OFFSET_BITS=64" \
      AR="${AR}" RANLIB="${RANLIB}" libbz2.a \
 && install -d ${SYSROOT}/include ${SYSROOT}/lib \
 && install -m 644 bzlib.h  ${SYSROOT}/include/ \
 && install -m 644 libbz2.a ${SYSROOT}/lib/ \
 && ${RANLIB} ${SYSROOT}/lib/libbz2.a \
 && cd /build && rm -rf bzip2-*

# ---------------------------------------------------------------------------
# xz / liblzma
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q \
      "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" \
 && tar xf xz-${XZ_VER}.tar.gz && cd xz-${XZ_VER} \
 && ./configure ${HOST_FLAG} --prefix=${SYSROOT} \
      --enable-static --disable-shared --disable-doc \
      --disable-lzmadec --disable-lzmainfo --disable-scripts \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf xz-*

# ---------------------------------------------------------------------------
# OpenSSL 3  (https / rtmps)
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" \
 && tar xf openssl-${OPENSSL_VER}.tar.gz && cd openssl-${OPENSSL_VER} \
 && OPENSSL_CROSS="" \
 && if [ "$BUILD_TARGET" = "win64" ]; then \
      # --cross-compile-prefix prepends the prefix to OpenSSL's internal tool names (gcc,
      # ar, ranlib, windres…).  env.sh already exported CC=x86_64-w64-mingw32-gcc, so
      # leaving CC set would produce x86_64-w64-mingw32-x86_64-w64-mingw32-gcc.
      # Unset the tool vars and let --cross-compile-prefix be the single source of truth.
      unset CC CXX AR NM RANLIB STRIP; \
      OPENSSL_CROSS="--cross-compile-prefix=${TARGET_TRIPLE}-"; \
    fi \
 && ./Configure ${OPENSSL_TARGET} \
      ${OPENSSL_CROSS} \
      --prefix=${SYSROOT} --openssldir=${SYSROOT}/ssl \
      --libdir=lib \
      no-shared no-tests no-apps \
 && make -j$(nproc) || make -j$(nproc) \
 && make install_sw \
 && cd /build && rm -rf openssl-*

# ---------------------------------------------------------------------------
# libogg
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.gz" \
 && tar xf libogg-${OGG_VER}.tar.gz && cd libogg-${OGG_VER} \
 && ./configure ${HOST_FLAG} --prefix=${SYSROOT} \
      --enable-static --disable-shared \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf libogg-*

# ---------------------------------------------------------------------------
# libvorbis
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q \
      "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.gz" \
 && tar xf libvorbis-${VORBIS_VER}.tar.gz && cd libvorbis-${VORBIS_VER} \
 && ./configure ${HOST_FLAG} --prefix=${SYSROOT} --with-ogg=${SYSROOT} \
      --enable-static --disable-shared --disable-oggtest \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf libvorbis-*

# ---------------------------------------------------------------------------
# Opus
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz" \
 && tar xf opus-${OPUS_VER}.tar.gz && cd opus-${OPUS_VER} \
 && ./configure ${HOST_FLAG} --prefix=${SYSROOT} \
      --enable-static --disable-shared --disable-doc --disable-extra-programs \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf opus-*

# ---------------------------------------------------------------------------
# libmp3lame
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q \
      "https://downloads.sourceforge.net/project/lame/lame/${LAME_VER}/lame-${LAME_VER}.tar.gz" \
 && tar xf lame-${LAME_VER}.tar.gz && cd lame-${LAME_VER} \
 && ./configure ${HOST_FLAG} --prefix=${SYSROOT} \
      --enable-static --disable-shared \
      --disable-gtktest --disable-analyzer-hooks \
      --disable-decoder --disable-frontend \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf lame-*

# ---------------------------------------------------------------------------
# libvpx  (VP8 / VP9)
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q "https://github.com/webmproject/libvpx/archive/v${VPX_VER}.tar.gz" \
      -O libvpx-${VPX_VER}.tar.gz \
 && tar xf libvpx-${VPX_VER}.tar.gz && cd libvpx-${VPX_VER} \
 && LIBVPX_AS="${AS}" \
 && if [ "$BUILD_TARGET" = "x86_64" ]; then LIBVPX_AS=nasm; fi \
 && if [ "$BUILD_TARGET" = "win64" ]; then LIBVPX_AS=nasm; fi \
 && VPX_EXTRA="" \
 && if [ "$BUILD_TARGET" = "win64" ]; then \
      # Buster's MinGW GAS doesn't support .seh_savexmm for AVX-512 extended XMM registers
      VPX_EXTRA="--disable-avx512"; \
    fi \
 && CC=${CC} CXX=${CXX} AR=${AR} NM=${NM} STRIP=${STRIP} AS=${LIBVPX_AS} \
    ./configure --target=${VPX_TARGET} --prefix=${SYSROOT} \
      --enable-static --disable-shared \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --enable-vp8 --enable-vp9 --enable-runtime-cpu-detect \
      ${VPX_EXTRA} \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf libvpx-*

# ---------------------------------------------------------------------------
# dav1d  (AV1 decoder)
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q \
      "https://github.com/videolan/dav1d/archive/refs/tags/${DAV1D_VER}.tar.gz" \
      -O dav1d-${DAV1D_VER}.tar.gz \
 && tar xf dav1d-${DAV1D_VER}.tar.gz && cd dav1d-${DAV1D_VER} \
 && CROSS_OPT="" \
 && if [ "$IS_CROSS" = "1" ]; then CROSS_OPT="--cross-file /etc/meson/cross.ini"; fi \
 && meson setup _build ${CROSS_OPT} \
      --prefix=${SYSROOT} --default-library=static --buildtype=release \
      -Denable_tools=false -Denable_tests=false \
 && ninja -C _build -j$(nproc) && ninja -C _build install \
 && cd /build && rm -rf dav1d-*

# ---------------------------------------------------------------------------
# libx264  (GPL 2+)
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && wget -q \
      "https://code.videolan.org/videolan/x264/-/archive/${X264_VER}/x264-${X264_VER}.tar.gz" \
 && tar xf x264-${X264_VER}.tar.gz && cd x264-${X264_VER} \
 && X264_CROSS="" \
 && if [ "$IS_CROSS" = "1" ]; then X264_CROSS="--cross-prefix=${TARGET_TRIPLE}-"; fi \
 && if [ "$BUILD_TARGET" = "x86_64" ] || [ "$BUILD_TARGET" = "win64" ]; then \
        export AS=nasm; \
    elif [ "$IS_CROSS" = "1" ]; then \
        # ARM .S files need cpp preprocessing — use cross-gcc, not bare cross-as
        export AS="${CC}"; \
    fi \
 && ./configure \
      ${HOST_FLAG} \
      ${X264_CROSS} \
      --prefix=${SYSROOT} \
      --enable-static --disable-cli --disable-opencl \
      --enable-pic \
 && make -j$(nproc) && make install \
 && cd /build && rm -rf x264-*

# ---------------------------------------------------------------------------
# ffnvcodec  (NVIDIA codec headers — header-only)
# x86_64: NVENC/NVDEC/CUDA.  arm64: NVENC/NVDEC on Jetson boards.
# Links against the NVIDIA driver at runtime; no .so needed at build time.
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && if [ "$BUILD_TARGET" = "x86_64" ] || [ "$BUILD_TARGET" = "arm64" ] || [ "$BUILD_TARGET" = "win64" ]; then \
      wget -q \
        "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/${FFNVCODEC_VER}.tar.gz" \
        -O ffnvcodec-${FFNVCODEC_VER}.tar.gz \
      && tar xf ffnvcodec-${FFNVCODEC_VER}.tar.gz \
      && cd nv-codec-headers-${FFNVCODEC_VER} \
      && make install PREFIX=${SYSROOT} \
      && cd /build && rm -rf nv-codec-headers-* ffnvcodec-*; \
    fi

# ---------------------------------------------------------------------------
# AMF  (AMD Advanced Media Framework headers — header-only, x86_64 only)
# Enables hardware H.264/H.265/AV1 encode on AMD GPUs via --enable-amf.
# AMD driver loaded at runtime; nothing shipped in the output tarball.
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && if [ "$BUILD_TARGET" = "x86_64" ] || [ "$BUILD_TARGET" = "win64" ]; then \
      wget -q \
        "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v${AMF_VER}.tar.gz" \
        -O amf-${AMF_VER}.tar.gz \
      && tar xf amf-${AMF_VER}.tar.gz \
      && mkdir -p ${SYSROOT}/include/AMF \
      && cp -r AMF-${AMF_VER}/amf/public/include/. ${SYSROOT}/include/AMF/ \
      && cd /build && rm -rf AMF-* amf-*; \
    fi

# ---------------------------------------------------------------------------
# Vulkan headers  (arm64 and x86_64 — not needed for armhf)
# Debian bullseye ships Vulkan 1.2.162; FFmpeg 8.1 requires >= 1.3.277.
# We get up-to-date headers from KhronosGroup and pair them with the
# libvulkan.so runtime from apt (the loader ABI is stable across versions).
# A correct vulkan.pc is written so FFmpeg's configure version check passes.
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && if [ "$BUILD_TARGET" != "armhf" ]; then \
      wget -q \
        "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v${VULKAN_VER}.tar.gz" \
        -O vulkan-headers-${VULKAN_VER}.tar.gz \
      && tar xf vulkan-headers-${VULKAN_VER}.tar.gz \
      && cp -r Vulkan-Headers-${VULKAN_VER}/include/vulkan ${SYSROOT}/include/ \
      && cp -r Vulkan-Headers-${VULKAN_VER}/include/vk_video ${SYSROOT}/include/ \
      \
      && if [ "$BUILD_TARGET" = "x86_64" ]; then \
           VKLIB=/usr/lib/x86_64-linux-gnu; \
         else \
           VKLIB=/usr/lib/aarch64-linux-gnu; \
         fi \
      && for f in ${VKLIB}/libvulkan*; do \
           [ -e "$f" ] && cp -P "$f" ${SYSROOT}/lib/ || true; \
         done \
      \
      && mkdir -p ${SYSROOT}/lib/pkgconfig \
      && printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: Vulkan-Loader\nDescription: Vulkan Loader\nVersion: %s\nLibs: -L${libdir} -lvulkan\nCflags: -I${includedir}\n' \
           "${SYSROOT}" "${VULKAN_VER}" > ${SYSROOT}/lib/pkgconfig/vulkan.pc \
      \
      && cd /build && rm -rf Vulkan-Headers-* vulkan-headers-*; \
    fi

# ---------------------------------------------------------------------------
# libdrm  (arm64 only — needed for DRM Prime memory with Rockchip MPP)
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && if [ "$BUILD_TARGET" = "arm64" ]; then \
      wget -q \
        "https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM_VER}.tar.xz" \
      && tar xf libdrm-${LIBDRM_VER}.tar.xz && cd libdrm-${LIBDRM_VER} \
      && meson setup _build \
           --cross-file /etc/meson/cross.ini \
           --prefix=${SYSROOT} \
           --default-library=static \
           --buildtype=release \
           -Dudev=false \
           -Dtests=false \
           -Dman-pages=disabled \
      && ninja -C _build -j$(nproc) && ninja -C _build install \
      && cd /build && rm -rf libdrm-*; \
    fi

# ---------------------------------------------------------------------------
# Rockchip MPP  (rockchip only — VPU H.264/H.265 hardware codec)
# Built as shared library; shipped in the output tarball alongside FFmpeg.
# Target device needs the rkvdec / mpp_service kernel driver.
#
# Source: nyanmisaka/rk-mirrors (jellyfin-mpp-next branch)
#   - rockchip-linux/mpp was DMCA taken down December 2025
#   - HermanChen/mpp cmake install doesn't put headers in include/rockchip/
#   - nyanmisaka/rk-mirrors is maintained by Jellyfin and has correct cmake
#     install rules; it is the same source Jellyfin uses in production
# ---------------------------------------------------------------------------
RUN . /env.sh && set -eux \
 && if [ "$BUILD_TARGET" = "arm64" ]; then \
      git clone -b jellyfin-mpp-next --depth=1 \
        https://github.com/nyanmisaka/rk-mirrors.git rkmpp \
      && cd rkmpp \
      && cmake -B _build \
           -DCMAKE_BUILD_TYPE=Release \
           -DCMAKE_INSTALL_PREFIX=${SYSROOT} \
           -DCMAKE_C_COMPILER=/usr/bin/${TARGET_TRIPLE}-gcc \
           -DCMAKE_CXX_COMPILER=/usr/bin/${TARGET_TRIPLE}-g++ \
           -DCMAKE_AR=/usr/bin/${TARGET_TRIPLE}-ar \
           -DCMAKE_RANLIB=/usr/bin/${TARGET_TRIPLE}-ranlib \
           -DCMAKE_C_COMPILER_AR=/usr/bin/${TARGET_TRIPLE}-ar \
           -DCMAKE_CXX_COMPILER_AR=/usr/bin/${TARGET_TRIPLE}-ar \
           -DCMAKE_C_COMPILER_RANLIB=/usr/bin/${TARGET_TRIPLE}-ranlib \
           -DCMAKE_CXX_COMPILER_RANLIB=/usr/bin/${TARGET_TRIPLE}-ranlib \
           -DCMAKE_STRIP=/usr/bin/${TARGET_TRIPLE}-strip \
           -DCMAKE_SYSTEM_NAME=Linux \
           -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
           -DBUILD_SHARED_LIBS=ON \
           -DBUILD_TEST=OFF \
      && cmake --build _build -- -j$(nproc) \
      && cmake --build _build --target install \
      \
      # cmake install does not copy public headers in cross-compile mode.
      # Manually install from the source inc/ tree (standard MPP header location).
      # FFmpeg's configure test does: #include <rockchip/rk_mpi.h>
      # so headers must land in ${SYSROOT}/include/rockchip/*.h
      && mkdir -p ${SYSROOT}/include/rockchip \
      && find inc -maxdepth 1 -name "*.h" -exec cp {} ${SYSROOT}/include/rockchip/ \; \
      && echo "=== MPP headers installed ===" && ls ${SYSROOT}/include/rockchip/ \
      \
      # Write pkg-config.
      # Cflags: -I${includedir} (i.e. .../include) so that
      #   #include <rockchip/rk_mpi.h> resolves via .../include/rockchip/rk_mpi.h
      # NOT -I${includedir}/rockchip (that would require bare <rk_mpi.h>).
      && mkdir -p ${SYSROOT}/lib/pkgconfig \
      && printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: rockchip_mpp\nDescription: Rockchip Media Process Platform\nVersion: 1.3.8\nLibs: -L${libdir} -lrockchip_mpp\nCflags: -I${includedir}\n' \
           "${SYSROOT}" > ${SYSROOT}/lib/pkgconfig/rockchip_mpp.pc \
      \
      && cd /build && rm -rf rkmpp; \
    fi

# ============================================================================
# FFmpeg  —  GPL 3+  ·  shared libraries
# ============================================================================
RUN . /env.sh && set -eux \
 && wget -q "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz" \
 && tar xf ffmpeg-${FFMPEG_VER}.tar.xz \
 && echo "=== extracted dirs ===" && ls -d ffmpeg-* 2>/dev/null || true \
 \
 # Verify MPP headers and pkg-config are in place before configure
 && if [ "$BUILD_TARGET" = "arm64" ]; then \
      echo "=== MPP header check ===" \
      && ls ${SYSROOT}/include/rockchip/ 2>/dev/null \
           || { echo "ERROR: ${SYSROOT}/include/rockchip/ missing — MPP headers not installed"; exit 1; } \
      && echo "=== rockchip_mpp.pc ===" \
      && cat ${SYSROOT}/lib/pkgconfig/rockchip_mpp.pc \
      && PKG_CONFIG_PATH=${PKG_CONFIG_PATH} pkg-config --modversion rockchip_mpp \
           || { echo "ERROR: rockchip_mpp not visible to pkg-config"; exit 1; }; \
    fi \
 \
 && cd ffmpeg-${FFMPEG_VER} \
 && CROSS_COMPILE_FLAGS="" \
 && if [ "$IS_CROSS" = "1" ]; then \
      CROSS_COMPILE_FLAGS="--cross-prefix=${TARGET_TRIPLE}- --enable-cross-compile --target-os=${FF_OS}"; \
    fi \
 && ./configure \
      --prefix=${FFMPEG_PREFIX} \
      \
      ${FF_ARCH_FLAGS} \
      ${FF_EXTRA_FLAGS} \
      ${CROSS_COMPILE_FLAGS} \
      \
      --pkg-config=${PKG_CONFIG} \
      --pkg-config-flags="--static" \
      \
      --extra-cflags="${CFLAGS} -I${SYSROOT}/include" \
      --extra-ldflags="-L${SYSROOT}/lib" \
      --extra-libs="${EXTRA_LIBS}" \
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
      ${FF_HW_FLAGS} \
      \
      ${FF_WIN_FLAGS} \
      \
      --disable-ffplay \
      --disable-ffprobe \
      || { echo "=== ffmpeg configure failed ==="; \
           if [ -f ffbuild/config.log ]; then \
             echo "--- last 100 lines of config.log ---"; \
             tail -100 ffbuild/config.log; \
           else \
             echo "--- config.log does not exist (configure crashed before creating it) ---"; \
             echo "--- current dir: $(pwd), contents: ---"; \
             ls -la; \
           fi; \
           exit 1; } \
 && make -j$(nproc) \
 && make install \
 \
 # Strip output binaries — paths and extensions differ between Linux and Windows
 && if [ "$BUILD_TARGET" = "win64" ]; then \
      find ${FFMPEG_PREFIX}/bin -name 'ffmpeg.exe' \
           -exec ${STRIP} {} \; 2>/dev/null || true; \
      find ${FFMPEG_PREFIX}/bin -name '*.dll' \
           -exec ${STRIP} --strip-unneeded {} \;; \
    else \
      ${STRIP} ${FFMPEG_PREFIX}/bin/ffmpeg; \
      find ${FFMPEG_PREFIX}/lib -name '*.so.*' \
           -exec ${STRIP} --strip-unneeded {} \;; \
    fi \
 \
 # Copy Rockchip MPP shared libs into the output so the tarball is self-contained
 && if [ "$BUILD_TARGET" = "arm64" ]; then \
      cp -P ${SYSROOT}/lib/librockchip_mpp*.so* ${FFMPEG_PREFIX}/lib/; \
    fi \
 \
 && cd /build && rm -rf ffmpeg-*

# ============================================================================
# Dist stage — minimal image: nothing but /ffmpeg
# Use:  docker build --target dist --build-arg TARGET=arm64 -t ffmpeg-arm64-dist .
# Then: docker create --name tmp ffmpeg-arm64-dist && \
#       docker cp tmp:/ffmpeg ./dist && docker rm tmp
# ============================================================================
FROM scratch AS dist
COPY --from=builder /opt/ffmpeg /ffmpeg
