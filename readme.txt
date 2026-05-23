FFmpeg ARM/x86 Cross-Build
==========================

Builds FFmpeg 8.1 as shared libraries (.so) for three target platforms,
cross-compiled from Windows using Docker. Output is a self-contained .tar.xz
that can be unpacked directly onto the target device.

Built against glibc 2.28 (Debian Buster base), so binaries run on any Linux
system with glibc >= 2.28: Raspberry Pi OS Buster+, Ubuntu 18.10+,
Debian Buster+, RHEL/CentOS 8+, Rockchip boards, NVIDIA JetPack 5+.


REQUIREMENTS
------------
  - Docker Desktop (with Linux containers)
  - PowerShell 5.1 or later


TARGETS
-------
  armhf   Raspberry Pi 2 / 3 / 4 / Zero 2 W and any ARMv7 hard-float Linux
  arm64   Raspberry Pi 3/4/5 (64-bit OS), Rockchip RK3566/RK3568/RK3588,
          NVIDIA Jetson, and any other aarch64 Linux board
  x86_64  Standard Linux desktop or server


BUILDING
--------
Open PowerShell in this folder and run:

  .\build.ps1                          # armhf (default)
  .\build.ps1 -Target arm64
  .\build.ps1 -Target x86_64

Output lands in the dist\ folder:

  dist\ffmpeg8.1-linux-armhf.tar.xz
  dist\ffmpeg8.1-linux-arm64.tar.xz
  dist\ffmpeg8.1-linux-x86_64.tar.xz

Build options:

  -Target    armhf | arm64 | x86_64       (default: armhf)
  -FfmpegVer 8.1                          (default: 8.1)
  -OutDir    .\dist                        (default: .\dist)
  -NoCache                                 force a clean rebuild, no Docker cache

Examples:

  .\build.ps1 -Target arm64 -NoCache
  .\build.ps1 -Target x86_64 -FfmpegVer 8.1 -OutDir C:\output


DEPLOYING
---------
Copy the tarball to the target device and unpack into /usr/local:

  scp dist\ffmpeg8.1-linux-arm64.tar.xz user@<device>:~/
  ssh user@<device>
  sudo tar -xJf ffmpeg8.1-linux-arm64.tar.xz -C /usr/local
  sudo ldconfig

FFmpeg will then be available at /usr/local/bin/ffmpeg.


HARDWARE ACCELERATION
---------------------
Hardware acceleration is compiled in where supported. Each accelerator
requires the appropriate driver to be present on the target device at
runtime — nothing extra needs to be installed from this package.

  armhf
    V4L2 M2M       Kernel video codec interface. Enables hardware H.264
                   decode on Raspberry Pi 4/5 via the onboard VPU.
                   Requires: raspberry pi kernel with bcm2835-codec driver.

  arm64
    V4L2 M2M       As above.
    Rockchip MPP   Hardware H.264/H.265 encode and decode on Rockchip SoCs
                   (RK3566, RK3568, RK3588). Silently ignored at runtime on
                   non-Rockchip boards.
                   Requires: rkvdec / mpp_service kernel driver.
    NVENC / NVDEC  NVIDIA hardware encode/decode on Jetson boards (Nano,
                   Xavier, Orin). NVIDIA driver loaded at runtime.
    Vulkan         GPU-accelerated processing on Mali GPUs and Raspberry Pi 5
                   VideoCore VII. Vulkan ICD driver required on device.

  x86_64
    VA-API         Intel and AMD hardware decode/encode. Works with the i915,
                   amdgpu, and radeonsi Mesa drivers.
    NVENC / NVDEC  NVIDIA hardware encode/decode. Requires NVIDIA proprietary
                   driver on the target machine.
    Vulkan         GPU-accelerated processing on Intel, AMD, and NVIDIA GPUs.
    AMF            AMD Advanced Media Framework hardware encode. Requires AMD
                   driver on the target machine.

To use hardware acceleration, pass the appropriate -hwaccel flag to ffmpeg:

  ffmpeg -hwaccel vaapi   -i input.mp4 ...   # Intel/AMD on x86_64
  ffmpeg -hwaccel cuda    -i input.mp4 ...   # NVIDIA (nvdec)
  ffmpeg -hwaccel rkmpp   -i input.mp4 ...   # Rockchip boards
  ffmpeg -hwaccel v4l2m2m -i input.mp4 ...   # Raspberry Pi VPU


INCLUDED CODEC LIBRARIES
-------------------------
  libx264      H.264 encoder                        GPL 2+
  libvpx       VP8 / VP9 encoder and decoder        BSD
  dav1d        AV1 decoder                          BSD
  libopus      Opus encoder and decoder             BSD
  libvorbis    Vorbis encoder and decoder           BSD
  libmp3lame   MP3 encoder                          LGPL 2
  OpenSSL 3    TLS — enables https:// and rtmps://  Apache 2.0

All native FFmpeg decoders are also included (H.264, H.265, AAC, MJPEG,
MPEG-2, AC3, DTS, FLAC, ProRes, and hundreds more). No external library
is needed to decode these formats.

This build is licenced under GPL 2+ (due to libx264).


BUMPING VERSIONS
----------------
All version pins are at the top of the Dockerfile under "Version pins".
To update a dependency, change the relevant ARG and rebuild with -NoCache
from that point downward. Docker layer caching means only the changed
dependency and everything below it will recompile.

  ARG FFMPEG_VER    FFmpeg
  ARG OPENSSL_VER   OpenSSL
  ARG DAV1D_VER     dav1d AV1 decoder
  ARG AMF_VER       AMD AMF headers
  ARG FFNVCODEC_VER NVIDIA codec headers
  ARG LIBDRM_VER    libdrm (arm64 Rockchip)
  ARG MPP_VER       Rockchip MPP (arm64)
  ... and others listed in the Dockerfile
