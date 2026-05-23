# syntax=docker/dockerfile:1
#
# FFmpeg cross-build  ·  armhf / Raspberry Pi  ·  glibc ≥ 2.31
# Variant : GPL  ·  shared libraries (.so)
# Inspired by BtbN/FFmpeg-Builds  (github.com/BtbN/FFmpeg-Builds)
#
# ── Build ────────────────────────────────────────────────────────────────────
#   docker build -t ffmpeg-armhf-build .
#
# ── Extract artifacts ────────────────────────────────────────────────────────
#   mkdir -p dist
#   docker run --rm -v "$PWD/dist":/out ffmpeg-armhf-build \
#       sh -c "cp -r /opt/ffmpeg/. /out/"
#
# dist/ will contain  bin/  include/  lib/  share/
# Deployables for the Pi:  bin/ffmpeg  bin/ffprobe  lib/*.so.*
#
# ── Target ───────────────────────────────────────────────────────────────────
#   Raspberry Pi 2 / 3 / 4 / Zero 2 W and any Debian Bullseye armhf system.
#   For Pi 1 / Zero (ARMv6), change cpu flags in the CFLAGS and FFmpeg
#   configure sections below (armv6 / -mfpu=vfp).
#
# ── Licence note ─────────────────────────────────────────────────────────────
#   --enable-gpl  → GPL 2+ build (required for libx264).
#   Included third-party codecs and their licences:
#     libx264     GPL 2+
#     libopus     BSD / RFC-6716
#     libvorbis   BSD
#     libmp3lame  LGPL 2
#     libvpx      BSD
#     libass      ISC   (subtitle rendering; GPL-compatible)
#     OpenSSL 3   Apache 2.0

# ============================================================================
# Version pins – bump here only
# ============================================================================
ARG FFMPEG_VER=8.1
ARG ZLIB_VER=1.3.1
ARG BZIP2_VER=1.0.8
ARG XZ_VER=5.6.2
ARG OPENSSL_VER=3.3.2
ARG OGG_VER=1.3.5
ARG VORBIS_VER=1.3.7
ARG OPUS_VER=1.5.2
ARG LAME_VER=3.100
ARG VPX_VER=1.14.1
ARG FREETYPE_VER=2.13.2
ARG FRIBIDI_VER=1.0.15
ARG HARFBUZZ_VER=9.0.0
ARG ASS_VER=0.17.3
ARG X264_VER=stable

# ============================================================================
# Builder
# ============================================================================
FROM debian:bullseye AS builder

# Propagate all ARGs into this stage
ARG FFMPEG_VER ZLIB_VER BZIP2_VER XZ_VER OPENSSL_VER
ARG OGG_VER VORBIS_VER OPUS_VER LAME_VER VPX_VER
ARG FREETYPE_VER FRIBIDI_VER HARFBUZZ_VER ASS_VER X264_VER

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Host toolchain & build utilities
# ---------------------------------------------------------------------------
RUN dpkg --add-architecture armhf \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      # Cross-compiler suite
      gcc-arm-linux-gnueabihf \
      g++-arm-linux-gnueabihf \
      binutils-arm-linux-gnueabihf \
      # Build systems
      cmake \
      ninja-build \
      meson \
      make \
      autoconf \
      automake \
      libtool \
      nasm \
      yasm \
      pkg-config \
      # Python (required by some dep build scripts)
      python3 \
      # Fetch & unpack
      wget \
      ca-certificates \
      xz-utils \
      bzip2 \
      # Misc
      patch \
      texinfo \
      gettext \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Cross-compilation environment
# ---------------------------------------------------------------------------
ENV TARGET_TRIPLE=arm-linux-gnueabihf
ENV CROSS_PREFIX=${TARGET_TRIPLE}-
ENV SYSROOT=/opt/x-sysroot
ENV FFMPEG_PREFIX=/opt/ffmpeg

# Toolchain binaries
ENV CC=${CROSS_PREFIX}gcc        \
    CXX=${CROSS_PREFIX}g++       \
    AR=${CROSS_PREFIX}ar         \
    AS=${CROSS_PREFIX}as         \
    LD=${CROSS_PREFIX}ld         \
    NM=${CROSS_PREFIX}nm         \
    STRIP=${CROSS_PREFIX}strip   \
    RANLIB=${CROSS_PREFIX}ranlib \
    OBJCOPY=${CROSS_PREFIX}objcopy

# Optimise for ARMv7-A + NEON (Pi 2/3/4/Zero2).
# -fPIC is mandatory: static deps will be linked into shared FFmpeg .so files.
ENV CFLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard \
            -O2 -pipe -fPIC -fstack-protector-strong" \
    CXXFLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard \
              -O2 -pipe -fPIC -fstack-protector-strong" \
    CPPFLAGS="-I${SYSROOT}/include" \
    LDFLAGS="-L${SYSROOT}/lib"

# Cross pkg-config wrapper — mirrors BtbN util/cross-pkg-config:
# forces static resolution and points at our sysroot.
RUN printf '#!/bin/sh\nexec pkg-config "$@"\n' \
      > /usr/local/bin/${TARGET_TRIPLE}-pkg-config \
 && chmod +x /usr/local/bin/${TARGET_TRIPLE}-pkg-config

ENV PKG_CONFIG=/usr/local/bin/${TARGET_TRIPLE}-pkg-config \
    PKG_CONFIG_PATH=${SYSROOT}/lib/pkgconfig:${SYSROOT}/share/pkgconfig \
    PKG_CONFIG_LIBDIR=${SYSROOT}/lib/pkgconfig:${SYSROOT}/share/pkgconfig

# Meson cross-file (used by fribidi if its autoconf bootstrap is absent)
RUN mkdir -p /etc/meson ${SYSROOT} ${FFMPEG_PREFIX} \
 && cat > /etc/meson/cross-armhf.ini <<'EOF'
[binaries]
c         = 'arm-linux-gnueabihf-gcc'
cpp       = 'arm-linux-gnueabihf-g++'
ar        = 'arm-linux-gnueabihf-ar'
strip     = 'arm-linux-gnueabihf-strip'
pkgconfig = 'arm-linux-gnueabihf-pkg-config'

[host_machine]
system     = 'linux'
cpu_family = 'arm'
cpu        = 'armv7'
endian     = 'little'
EOF

WORKDIR /build

# ============================================================================
# Third-party dependencies
# All built as static libs so they are baked into the FFmpeg .so files,
# leaving the Pi binary with no external .so deps beyond glibc.
# ============================================================================

# ---------------------------------------------------------------------------
# zlib
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" \
 && tar xf zlib-${ZLIB_VER}.tar.gz && cd zlib-${ZLIB_VER} \
 && CHOST=${TARGET_TRIPLE} CC=${CC} CFLAGS="${CFLAGS}" \
    ./configure \
      --prefix=${SYSROOT} \
      --static \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf zlib-*

# ---------------------------------------------------------------------------
# bzip2  (hand-rolled Makefile, no autoconf)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VER}.tar.gz" \
 && tar xf bzip2-${BZIP2_VER}.tar.gz && cd bzip2-${BZIP2_VER} \
 && make -j$(nproc) \
      CC="${CC}" \
      CFLAGS="${CFLAGS} -Wall -Winline -D_FILE_OFFSET_BITS=64" \
      AR="${AR}" \
      RANLIB="${RANLIB}" \
      libbz2.a \
 && install -d ${SYSROOT}/include ${SYSROOT}/lib \
 && install -m 644 bzlib.h  ${SYSROOT}/include/ \
 && install -m 644 libbz2.a ${SYSROOT}/lib/ \
 && ${RANLIB} ${SYSROOT}/lib/libbz2.a \
 && cd /build && rm -rf bzip2-*

# ---------------------------------------------------------------------------
# xz / liblzma
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz" \
 && tar xf xz-${XZ_VER}.tar.gz && cd xz-${XZ_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-doc \
      --disable-lzmadec \
      --disable-lzmainfo \
      --disable-scripts \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf xz-*

# ---------------------------------------------------------------------------
# OpenSSL 3  (Apache 2.0 — LGPL-compatible)
# linux-armv4 is the canonical OpenSSL target for all ARMv4T+ including ARMv7
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" \
 && tar xf openssl-${OPENSSL_VER}.tar.gz && cd openssl-${OPENSSL_VER} \
 && ./Configure linux-armv4 \
      --prefix=${SYSROOT} \
      --openssldir=${SYSROOT}/ssl \
      no-shared \
      no-tests \
      no-apps \
 && make -j$(nproc) || make -j$(nproc) \
 && make install_sw \
 && cd /build && rm -rf openssl-*

# ---------------------------------------------------------------------------
# libogg  (needed by vorbis)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.gz" \
 && tar xf libogg-${OGG_VER}.tar.gz && cd libogg-${OGG_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf libogg-*

# ---------------------------------------------------------------------------
# libvorbis
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.gz" \
 && tar xf libvorbis-${VORBIS_VER}.tar.gz && cd libvorbis-${VORBIS_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --with-ogg=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-oggtest \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf libvorbis-*

# ---------------------------------------------------------------------------
# Opus
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz" \
 && tar xf opus-${OPUS_VER}.tar.gz && cd opus-${OPUS_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-doc \
      --disable-extra-programs \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf opus-*

# ---------------------------------------------------------------------------
# libmp3lame  (LGPL 2)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://downloads.sourceforge.net/project/lame/lame/${LAME_VER}/lame-${LAME_VER}.tar.gz" \
 && tar xf lame-${LAME_VER}.tar.gz && cd lame-${LAME_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-gtktest \
      --disable-analyzer-hooks \
      --disable-decoder \
      --disable-frontend \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf lame-*

# ---------------------------------------------------------------------------
# libvpx  (VP8 / VP9 — BSD)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://github.com/webmproject/libvpx/archive/v${VPX_VER}.tar.gz" \
      -O libvpx-${VPX_VER}.tar.gz \
 && tar xf libvpx-${VPX_VER}.tar.gz && cd libvpx-${VPX_VER} \
 && CC=${CC} CXX=${CXX} AR=${AR} NM=${NM} STRIP=${STRIP} \
    ./configure \
      --target=armv7-linux-gcc \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-examples \
      --disable-tools \
      --disable-docs \
      --disable-unit-tests \
      --enable-vp8 \
      --enable-vp9 \
      --enable-runtime-cpu-detect \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf libvpx-*

# ---------------------------------------------------------------------------
# FreeType  (needed by libass for glyph rasterisation)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.gz" \
 && tar xf freetype-${FREETYPE_VER}.tar.gz && cd freetype-${FREETYPE_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --without-harfbuzz \
      --without-brotli \
      --without-bzip2 \
      --without-png \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf freetype-*

# ---------------------------------------------------------------------------
# fribidi  (needed by libass for BiDi text)
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz" \
 && tar xf fribidi-${FRIBIDI_VER}.tar.xz && cd fribidi-${FRIBIDI_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-docs \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf fribidi-*

# ---------------------------------------------------------------------------
# harfbuzz  (required by libass 0.17+)
# Uses meson + the cross-file we wrote earlier.
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz" \
 && tar xf harfbuzz-${HARFBUZZ_VER}.tar.xz && cd harfbuzz-${HARFBUZZ_VER} \
 && meson setup _build \
      --cross-file /etc/meson/cross-armhf.ini \
      --prefix=${SYSROOT} \
      --default-library=static \
      --buildtype=release \
      -Dfreetype=enabled \
      -Dglib=disabled \
      -Dgobject=disabled \
      -Dicu=disabled \
      -Dcairo=disabled \
      -Dtests=disabled \
      -Ddocs=disabled \
      -Dbenchmark=disabled \
      -Dintrospection=disabled \
 && ninja -C _build -j$(nproc) \
 && ninja -C _build install \
 && cd /build && rm -rf harfbuzz-*

# ---------------------------------------------------------------------------
# libass  (subtitle rendering — ISC licence, GPL-compatible)
# fontconfig disabled: embedded fonts in container/MKV still work fine.
# Add harfbuzz + fontconfig build steps above if you need system font lookup.
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://github.com/libass/libass/releases/download/${ASS_VER}/libass-${ASS_VER}.tar.gz" \
 && tar xf libass-${ASS_VER}.tar.gz && cd libass-${ASS_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-fontconfig \
      --disable-require-system-font-provider \
 && make -j$(nproc) \
 && make install \
 && cd /build && rm -rf libass-*

# ---------------------------------------------------------------------------
# libx264  (GPL 2+)
# x264 uses snapshot numbering; "stable" tracks the stable branch.
# ---------------------------------------------------------------------------
RUN set -eux \
 && wget -q \
      "https://code.videolan.org/videolan/x264/-/archive/${X264_VER}/x264-${X264_VER}.tar.gz" \
 && tar xf x264-${X264_VER}.tar.gz && cd x264-${X264_VER} \
 && ./configure \
      --host=${TARGET_TRIPLE} \
      --cross-prefix=${CROSS_PREFIX} \
      --prefix=${SYSROOT} \
      --enable-static \
      --disable-shared \
      --disable-cli \
      --disable-opencl \
      --enable-pic \
 && make -j$(nproc) AS=${CC} \
 && make install \
 && cd /build && rm -rf x264-*

# ============================================================================
# FFmpeg  —  GPL 2+  ·  shared libraries
# ============================================================================
RUN set -eux \
 && wget -q "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz" \
 && tar xf ffmpeg-${FFMPEG_VER}.tar.xz && cd ffmpeg-${FFMPEG_VER} \
 && ./configure \
      --prefix=${FFMPEG_PREFIX} \
      \
      # Cross-compilation \
      --arch=arm \
      --cpu=armv7-a \
      --target-os=linux \
      --cross-prefix=${CROSS_PREFIX} \
      --enable-cross-compile \
      \
      # pkg-config must resolve our sysroot static deps \
      --pkg-config=${PKG_CONFIG} \
      --pkg-config-flags="--static" \
      \
      --extra-cflags="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard \
                      -I${SYSROOT}/include" \
      --extra-ldflags="-L${SYSROOT}/lib" \
      # -latomic: required on armhf for 64-bit atomic ops in some gcc versions \
      --extra-libs="-lpthread -lm -latomic" \
      \
      # Output: shared libs, no static archives \
      --enable-shared \
      --disable-static \
      \
      # Licence: GPL 3+ (--enable-version3 required for OpenSSL 3.x / Apache 2.0) \
      --enable-gpl \
      --enable-version3 \
      --disable-nonfree \
      \
      # Reduce output size \
      --disable-debug \
      --disable-doc \
      --disable-htmlpages \
      --disable-manpages \
      --disable-podpages \
      --disable-txtpages \
      \
      # ARM optimisations \
      --enable-neon \
      --enable-vfp \
      --enable-armv6t2 \
      \
      # System libs (statically pulled from sysroot) \
      --enable-zlib \
      --enable-bzlib \
      --enable-lzma \
      --enable-openssl \
      \
      # LGPL codec libraries \
      --enable-libx264 \
      --enable-libopus \
      --enable-libvorbis \
      --enable-libvpx \
      --enable-libmp3lame \
      --enable-libass \
      \
      # ffplay requires SDL2 (not cross-built here) \
      --disable-ffplay \
 && make -j$(nproc) \
 && make install \
 \
 # Strip release binaries and shared libs \
 && ${STRIP} \
      ${FFMPEG_PREFIX}/bin/ffmpeg \
      ${FFMPEG_PREFIX}/bin/ffprobe \
 && find ${FFMPEG_PREFIX}/lib -name '*.so.*' -exec ${STRIP} --strip-unneeded {} \; \
 \
 && cd /build && rm -rf ffmpeg-*

# ============================================================================
# Dist stage — minimal image: nothing but /ffmpeg
# Use:  docker build --target dist -t ffmpeg-armhf-dist .
# Then: docker create --name tmp ffmpeg-armhf-dist && \
#       docker cp tmp:/ffmpeg ./dist && docker rm tmp
# ============================================================================
FROM scratch AS dist
COPY --from=builder /opt/ffmpeg /ffmpeg
