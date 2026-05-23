# build.ps1 — Cross-build FFmpeg and produce a deployable archive
# Usage:  .\build.ps1
#         .\build.ps1 -Target arm64
#         .\build.ps1 -Target x86_64 -FfmpegVer 8.1 -OutDir .\dist
#         .\build.ps1 -Target arm64 -NoCache
#         .\build.ps1 -Target win64          # produces a .7z archive
#
# Targets:  armhf (default)  arm64  x86_64  win64
#
# NOTE: --progress=plain is built in; do not pass it on the command line.
#       Use -Progress auto to suppress verbose output.
# NOTE: win64 requires 7-Zip (7z.exe) to be on PATH or at the default install path.

[CmdletBinding()]
param(
    [ValidateSet("armhf","arm64","x86_64","win64")]
    [string]$Target     = "armhf",
    [string]$FfmpegVer  = "8.1",
    [string]$OutDir     = "$PSScriptRoot\dist",
    [string]$ImageTag   = "",      # auto-derived from Target if empty
    [ValidateSet("plain","auto")]
    [string]$Progress   = "plain",
    [switch]$NoCache
)

$ErrorActionPreference = "Stop"

if (-not $ImageTag) { $ImageTag = "ffmpeg-${Target}-build" }

if ($Target -eq "win64") {
    $ArchiveName = "ffmpeg${FfmpegVer}-windows-x64.7z"
} else {
    $ArchiveName = "ffmpeg${FfmpegVer}-linux-${Target}.tar.xz"
}
$ArchivePath = Join-Path $OutDir $ArchiveName

# ---------------------------------------------------------------------------
Write-Host "`n==> Building Docker image: $ImageTag  (target: $Target)" -ForegroundColor Cyan
# ---------------------------------------------------------------------------

$BuildArgs = @(
    "build",
    "--target", "builder",
    "--progress", $Progress,
    "--build-arg", "FFMPEG_VER=$FfmpegVer",
    "--build-arg", "TARGET=$Target",
    "-t", $ImageTag
)
if ($NoCache) { $BuildArgs += "--no-cache" }
$BuildArgs += "."

$start = Get-Date
docker @BuildArgs
if ($LASTEXITCODE -ne 0) { throw "docker build failed (exit $LASTEXITCODE)" }

$elapsed = (Get-Date) - $start
Write-Host "    Build completed in $([math]::Round($elapsed.TotalMinutes, 1)) min" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host "`n==> Creating archive: $ArchivePath" -ForegroundColor Cyan
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir      = (Resolve-Path $OutDir).Path
$ArchivePath = Join-Path $OutDir $ArchiveName

if ($Target -eq "win64") {
    # Locate 7-Zip
    $7z = Get-Command "7z" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $7z) { $7z = "C:\Program Files\7-Zip\7z.exe" }
    if (-not (Test-Path $7z)) { throw "7-Zip not found. Install 7-Zip or add 7z.exe to PATH." }

    # Copy files out of the image via a temporary container, then 7z them.
    $TempDir = Join-Path $env:TEMP "ffmpeg-win64-$(New-Guid | Select-Object -ExpandProperty Guid)"
    $ContainerId = (docker create $ImageTag).Trim()
    try {
        New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
        # Copy only bin/ contents (DLLs + ffmpeg.exe); skip lib/, include/, share/
        docker cp "${ContainerId}:/opt/ffmpeg/bin/." $TempDir
        if ($LASTEXITCODE -ne 0) { throw "docker cp failed (exit $LASTEXITCODE)" }

        if (Test-Path $ArchivePath) { Remove-Item $ArchivePath }
        # .lib files are import libs for compile-time linking — not needed for FFmpeg.AutoGen
        & $7z a -t7z -mx=9 -mmt=on $ArchivePath "$TempDir\*.dll" "$TempDir\ffmpeg.exe"
        if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE)" }
    } finally {
        docker rm $ContainerId | Out-Null
        Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
    }
} else {
    # Stream tar directly out of the container via raw process stdout.
    # PowerShell's pipeline corrupts binary on PS 5.1, so we use
    # System.Diagnostics.Process to read the byte stream directly.
    $psi = [System.Diagnostics.ProcessStartInfo]::new("docker")
    $psi.Arguments              = "run --rm $ImageTag tar -cJf - -C /opt/ffmpeg ."
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outFile = [System.IO.File]::OpenWrite($ArchivePath)
    try   { $proc.StandardOutput.BaseStream.CopyTo($outFile) }
    finally { $outFile.Close() }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        $err = $proc.StandardError.ReadToEnd()
        throw "tar extraction failed: $err"
    }
}

$size = (Get-Item $ArchivePath).Length / 1MB
Write-Host "    $ArchivePath  ($([math]::Round($size, 1)) MB)" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host "`n==> Done." -ForegroundColor Cyan

switch ($Target) {
    "armhf"  {
        Write-Host "    Deploy to Pi (32-bit) with:" -ForegroundColor White
        Write-Host "    scp $ArchivePath pi@<host>:~/"
        Write-Host "    ssh pi@<host> 'sudo tar -xJf ~/$ArchiveName -C /usr/local && sudo ldconfig'"
    }
    "arm64"  {
        Write-Host "    Deploy to Pi (64-bit) / Rockchip / Jetson / aarch64 host with:" -ForegroundColor White
        Write-Host "    scp $ArchivePath user@<host>:~/"
        Write-Host "    ssh user@<host> 'sudo tar -xJf ~/$ArchiveName -C /usr/local && sudo ldconfig'"
        Write-Host "    Note: Rockchip MPP requires rkvdec/mpp_service kernel driver on RK boards" -ForegroundColor Yellow
    }
    "x86_64" {
        Write-Host "    Install on Linux x86_64 with:" -ForegroundColor White
        Write-Host "    sudo tar -xJf $ArchiveName -C /usr/local && sudo ldconfig"
    }
    "win64"  {
        Write-Host "    Extract $ArchiveName, then:" -ForegroundColor White
        Write-Host "    Copy bin\*.dll to your application directory (alongside your .exe)"
        Write-Host "    FFmpeg.AutoGen will find them via PATH or the application directory"
        Write-Host "    DLLs: avcodec, avformat, avutil, swscale, swresample, avfilter, avdevice" -ForegroundColor Yellow
    }
}
Write-Host ""
