# AgentDVR — FFmpeg cross-build (armhf / arm64 / x86_64 / win64)

This folder cross-builds **FFmpeg 8.1 GPL shared libraries** from source for the four platforms AgentDVR ships, targeting [FFmpeg.AutoGen 8.1](https://github.com/Ruslan-B/FFmpeg.AutoGen). All builds are done inside Docker on a Windows x86_64 dev machine.

## Why this exists

FFmpeg.AutoGen loads FFmpeg's shared libraries at runtime via P/Invoke. The libraries must be:

- **The right ABI version** — FFmpeg.AutoGen 8.1 expects the 8.1 `.so` / `.dll` ABI (avcodec 62, avformat 62, avutil 60, etc.).
- **GPL-licensed** — required for libx264 (H.264 encoding). FFmpeg's pre-built binaries are often LGPL-only.
- **glibc 2.28-compatible** — AgentDVR targets Debian 10 (Buster), Ubuntu 18.10+, RHEL 8+, and Raspberry Pi OS Buster.
- **Hardware-acceleration-enabled** — each platform needs its own HW accel flags; no single binary covers all.

## Targets

| Target    | Build base              | glibc floor | Hardware acceleration                                      |
|-----------|-------------------------|-------------|-------------------------------------------------------------|
| `armhf`   | Debian Buster (Docker)  | 2.28        | V4L2 M2M (Pi 2/3/4 H.264 kernel decoder)                  |
| `arm64`   | Debian Buster (Docker)  | 2.28        | V4L2 M2M · Rockchip MPP (RK3566/RK3568/RK3588) · NVENC/NVDEC (Jetson) · Vulkan |
| `x86_64`  | Debian Buster (Docker)  | 2.28        | VA-API (Intel/AMD) · NVENC/NVDEC (NVIDIA) · Vulkan · AMF (AMD) |
| `win64`   | MinGW-w64 (cross)       | Windows 10+ | D3D11VA · DXVA2 · NVENC/NVDEC (NVIDIA) · AMF (AMD)        |

## Codec libraries bundled

All dependencies are compiled statically into the FFmpeg `.so` / `.dll` files — nothing extra to deploy alongside them.

| Library     | Version | Licence     | Purpose                          |
|-------------|---------|-------------|----------------------------------|
| libx264     | stable  | GPL 2+      | H.264 encoder                    |
| libvpx      | 1.14.1  | BSD         | VP8 / VP9 encoder + decoder      |
| dav1d       | 1.4.1   | BSD         | AV1 decoder                      |
| libopus     | 1.5.2   | BSD         | Opus audio codec                 |
| libvorbis   | 1.3.7   | BSD         | Vorbis audio codec               |
| libmp3lame  | 3.100   | LGPL 2      | MP3 encoder                      |
| OpenSSL     | 3.4.1   | Apache 2.0  | HTTPS / RTMPS transport          |
| zlib        | 1.3.1   | zlib        | Deflate (MKV/MP4 metadata)       |
| bzip2       | 1.0.8   | BSD-like    | bzip2 demux                      |
| liblzma/xz  | 5.6.2   | Public Domain | xz/lzma demux                  |

### arm64 only

| Library       | Licence     | Purpose                                            |
|---------------|-------------|----------------------------------------------------|
| Rockchip MPP  | Apache 2.0  | Rockchip VPU H.264/H.265 hardware codec. Deployed as `librockchip_mpp.so` alongside the FFmpeg libs. The driver (`rkvdec` / `mpp_service`) must be present in the target kernel — on non-Rockchip boards FFmpeg simply won't find it at runtime and falls back to software. |
| libdrm        | MIT         | DRM Prime buffer sharing (required by rkmpp)       |

> **Note on Rockchip MPP source.** The canonical `rockchip-linux/mpp` repo was DMCA-taken-down in December 2025. This build clones `nyanmisaka/rk-mirrors` (branch `jellyfin-mpp-next`) — the same fork Jellyfin uses in production.

## Prerequisites

- **Docker Desktop** (Windows) with `docker buildx` available (bundled since Docker 20.10).
- **7-Zip** on PATH (or at the default `C:\Program Files\7-Zip\7z.exe`) — win64 output only.
- ~15 GB free disk per target for build layers.
- For arm64 / armhf emulation on an x64 host: QEMU binfmt handlers — the scripts install these automatically via `tonistiigi/binfmt`.

## Building

### PowerShell (Windows)

```powershell
# Default target: armhf
.\build.ps1

# Specific target
.\build.ps1 -Target armhf
.\build.ps1 -Target arm64
.\build.ps1 -Target x86_64
.\build.ps1 -Target win64

# Override FFmpeg version
.\build.ps1 -Target x86_64 -FfmpegVer 8.1

# Custom output directory
.\build.ps1 -Target arm64 -OutDir .\dist

# Force a full rebuild (no Docker layer cache)
.\build.ps1 -Target x86_64 -NoCache
```

### Bash (Linux / macOS / WSL)

```bash
./build.sh x64       # → linux-x86_64
./build.sh arm64     # → linux-arm64
./build.sh armhf     # → linux-armhf
./build.sh win64     # → windows-x64

# Override version / jobs
FFMPEG_VER=8.1 ./build.sh x64
```

## Outputs

### Linux targets (`armhf`, `arm64`, `x86_64`)

```
dist/
  ffmpeg8.1-linux-<target>.tar.xz
```

The archive contains `/bin/ffmpeg` and `/lib/libav*.so.*`, `/lib/libsw*.so.*`. Extract with:

```bash
sudo tar -xJf ffmpeg8.1-linux-arm64.tar.xz -C /usr/local && sudo ldconfig
```

The arm64 tarball also includes `librockchip_mpp.so` under `lib/`.

### Windows (`win64`)

```
dist/
  ffmpeg8.1-windows-x64.7z
```

The archive contains only the 7 DLLs and `ffmpeg.exe` at the root — no `.lib` import libraries, no `include/` tree. Drop the DLLs into your application directory alongside your `.exe` (or anywhere on `PATH`):

```
avcodec-62.dll
avdevice-62.dll
avfilter-11.dll
avformat-62.dll
avutil-60.dll
swresample-6.dll
swscale-9.dll
ffmpeg.exe
```

FFmpeg.AutoGen discovers them automatically via `PATH` or the application directory.

## Build options (ARGs / env vars)

| Parameter       | Default  | Description                                            |
|-----------------|----------|--------------------------------------------------------|
| `FFMPEG_VER`    | `8.1`    | FFmpeg release tag                                     |
| `TARGET`        | `armhf`  | Build target: `armhf` / `arm64` / `x86_64` / `win64`  |
| `NASM_VER`      | `2.16.03`| NASM version (built from source — Buster ships 2.14 which is too old for FFmpeg 8.1 AVX macros) |

All version pins are at the top of `Dockerfile` — bump them there to update a dependency.

## Licence note

`--enable-gpl` is required for libx264. The resulting binaries are **GPL 2+**. Do not distribute them in a closed-source product without complying with the GPL (source offer etc.).

## File map

| File          | Purpose                                                          |
|---------------|------------------------------------------------------------------|
| `Dockerfile`  | Single multi-target Dockerfile. `ARG TARGET` selects the target. |
| `build.ps1`   | PowerShell orchestrator — builds image and extracts archive.     |
| `build.sh`    | Bash equivalent for Linux / macOS / WSL.                         |
| `dist/`       | Created at build time. Holds output archives. Gitignored.        |

## Wiring into AgentDVR

AgentDVR's `Dependencies.cs` downloader expects the Linux tarballs at:

```
https://files.ispyconnect.com/libs/ffmpeg/<version>/linux-<target>.tar.xz
```

and the Windows archive at:

```
https://files.ispyconnect.com/libs/ffmpeg/<version>/windows-x64.7z
```

To roll a new version:

1. Build all targets.
2. Upload archives to the CDN under `libs/ffmpeg/<new-version>/`.
3. Bump the version constant in `Dependencies.cs`.

## Troubleshooting

**QEMU arm64 / armhf build hangs for hours.**  
Normal — QEMU emulation is slow. A native arm64 host (Raspberry Pi 5, AWS Graviton, GitHub Actions arm64 runner) is 4–10× faster.

**`GLIBC_2.X not found` on the target.**  
The `ldd` / `nm` checks in the Dockerfile verify this before exporting. If you see it at runtime, the wrong binary was deployed. Check that the archive matches the target arch.

**Rockchip MPP not found at runtime.**  
The kernel driver (`rkvdec` / `mpp_service`) must be loaded. Check `lsmod | grep rkvdec`. On non-Rockchip hardware, this is expected and FFmpeg falls back to software decode.

**win64 DLLs not found by FFmpeg.AutoGen.**  
Put the DLLs in the same directory as the application `.exe`, or anywhere on `PATH`. FFmpeg.AutoGen calls `LoadLibrary` with bare names (`avcodec-62.dll` etc.) — the Windows loader resolves from the application directory and then `PATH`.
