# build.ps1 — Cross-build FFmpeg armhf and produce a deployable tarball
# Usage:  .\build.ps1
#         .\build.ps1 -FfmpegVer 7.1 -OutDir .\dist

param(
    [string]$FfmpegVer = "8.1",
    [string]$OutDir    = "$PSScriptRoot\dist",
    [string]$ImageTag  = "ffmpeg-armhf-build",
    [switch]$NoCache
)

$ErrorActionPreference = "Stop"

$TarballName = "ffmpeg${FfmpegVer}-linuxarm.tar.xz"
$TarballPath = Join-Path $OutDir $TarballName

# ---------------------------------------------------------------------------
Write-Host "`n==> Building Docker image: $ImageTag" -ForegroundColor Cyan
# ---------------------------------------------------------------------------

$BuildArgs = @(
    "build",
    "--target", "builder",
    "--build-arg", "FFMPEG_VER=$FfmpegVer",
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
Write-Host "`n==> Creating tarball: $TarballPath" -ForegroundColor Cyan
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir     = (Resolve-Path $OutDir).Path
$TarballPath = Join-Path $OutDir $TarballName

# Stream tar directly out of the container via raw process stdout.
# PowerShell's pipeline corrupts binary on PS 5.1, so we use
# System.Diagnostics.Process to read the byte stream directly.
$psi = [System.Diagnostics.ProcessStartInfo]::new("docker")
$psi.Arguments       = "run --rm $ImageTag tar -cJf - -C /opt/ffmpeg ."
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$outFile = [System.IO.File]::OpenWrite($TarballPath)
try   { $proc.StandardOutput.BaseStream.CopyTo($outFile) }
finally { $outFile.Close() }
$proc.WaitForExit()
if ($proc.ExitCode -ne 0) {
    $err = $proc.StandardError.ReadToEnd()
    throw "tar extraction failed: $err"
}

if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)" }

$size = (Get-Item $TarballPath).Length / 1MB
Write-Host "    $TarballPath  ($([math]::Round($size, 1)) MB)" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host "`n==> Done.  Deploy to Pi with:" -ForegroundColor Cyan
Write-Host "    scp $TarballPath pi@<host>:~/" -ForegroundColor White
Write-Host "    ssh pi@<host> 'sudo tar -xzf ~/$TarballName -C /usr/local && sudo ldconfig'"
Write-Host ""
