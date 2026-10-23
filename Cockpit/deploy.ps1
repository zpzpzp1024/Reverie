<#
.SYNOPSIS
    Cockpit over SSH: install a deb, respring, print the tweak log.

.DESCRIPTION
    The device needs OpenSSH (Sileo: openssh) and the same Wi-Fi as this PC.
    Password auth works, but key auth is what makes this script painless:
    every ssh/scp call prompts for a password otherwise.

.EXAMPLE
    ./deploy.ps1 -Device 192.168.1.23 -Latest

.EXAMPLE
    ./deploy.ps1 -Device 192.168.1.23 -Deb .\Cockpit\packages\lilliana.cockpit_0.0.4_iphoneos-arm64.deb -Tail 120

.EXAMPLE
    ./deploy.ps1 -Device 192.168.1.23 -LogOnly -Follow
#>
[CmdletBinding()]
param(
    [string]$Device,
    [string]$Deb,
    [switch]$Latest,
    [switch]$NoRespring,
    [switch]$LogOnly,
    [switch]$Follow,
    [int]$Wait = 8,
    [int]$Tail = 0,
    [string]$SaveLog
)

$ErrorActionPreference = 'Stop'

if (-not $Device) { $Device = $env:COCKPIT_DEVICE }
if (-not $Device) { throw 'Pass -Device <ip> or set COCKPIT_DEVICE' }

$sshOptions = @(
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=15'
)
$target = "root@$Device"
$remoteLog = '/var/mobile/Library/Logs/Cockpit.log'

function Write-Step([string]$Text) {
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Invoke-Ssh([string]$Command) {
    & ssh @sshOptions $target $Command
    if ($LASTEXITCODE -ne 0) {
        throw "ssh failed (exit $LASTEXITCODE): $Command"
    }
}

function Get-LatestDeb {
    Write-Step 'Looking up the newest cockpit build'
    $headers = @{ 'User-Agent' = 'cockpit-deploy' }
    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/zpzpzp1024/Reverie/releases?per_page=30' -Headers $headers

    # The CI keeps a rolling "cockpit-latest" release; fall back to the newest
    # versioned cockpit-* release if it is missing.
    $release = $releases | Where-Object { $_.tag_name -eq 'cockpit-latest' } | Select-Object -First 1
    if (-not $release) {
        $release = $releases | Where-Object { $_.tag_name -like 'cockpit-*' } | Select-Object -First 1
    }
    if (-not $release) {
        throw 'No cockpit release found. Pass -Deb instead.'
    }

    $asset = $release.assets |
        Where-Object { $_.name -like '*.deb' } |
        Sort-Object created_at -Descending |
        Select-Object -First 1
    if (-not $asset) {
        throw "Release $($release.tag_name) has no .deb asset."
    }

    $path = Join-Path $env:TEMP $asset.name
    Write-Step "Downloading $($asset.name) ($($release.tag_name))"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -UseBasicParsing
    return $path
}

function Get-LocalDeb {
    if ($Deb) {
        if (-not (Test-Path $Deb)) { throw "Deb not found: $Deb" }
        return (Resolve-Path $Deb).Path
    }

    $candidates = Get-ChildItem -Path (Join-Path $PSScriptRoot 'packages') -Filter '*.deb' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime
    if (-not $candidates) {
        throw 'No deb in Cockpit/packages. Use -Latest or -Deb.'
    }
    return $candidates[-1].FullName
}

Write-Step "Connecting to $Device"
try {
    Invoke-Ssh 'echo connected' | Out-Null
}
catch {
    Write-Host ''
    Write-Host 'Cannot reach the device over SSH.' -ForegroundColor Red
    Write-Host 'Checklist:' -ForegroundColor Yellow
    Write-Host '  - Sileo has OpenSSH installed (package: openssh)'
    Write-Host '  - iPhone and PC are on the same Wi-Fi (router AP isolation off)'
    Write-Host '  - The IP is current: Settings > Wi-Fi > (i) > IP Address'
    Write-Host '  - Default password is alpine; change it with: passwd'
    throw
}

if ($LogOnly) {
    $command = if ($Tail -gt 0) { "tail -n $Tail $remoteLog" } else { "cat $remoteLog" }
    if ($Follow) {
        $followArgs = if ($Tail -gt 0) { "tail -n $Tail -f $remoteLog" } else { "tail -f $remoteLog" }
        Write-Step "Following $remoteLog (Ctrl+C to stop)"
        & ssh @sshOptions $target $followArgs
        return
    }
    Invoke-Ssh $command
    if ($SaveLog) {
        & scp @sshOptions "${target}:$remoteLog" $SaveLog
        Write-Step "Saved to $SaveLog"
    }
    return
}

if ($Latest -and $Deb) {
    throw 'Use either -Latest or -Deb, not both.'
}

$debPath = if ($Latest) { Get-LatestDeb } else { Get-LocalDeb }
$debName = Split-Path $debPath -Leaf
$size = (Get-Item $debPath).Length
Write-Step "Installing $debName ($size bytes)"

& scp @sshOptions $debPath "${target}:/var/mobile/cockpit.deb"
if ($LASTEXITCODE -ne 0) {
    throw 'scp failed.'
}

$install = @(
    'set -e',
    'DPKG=/var/jb/usr/bin/dpkg',
    '[ -x "$DPKG" ] || DPKG=$(command -v dpkg)',
    '"$DPKG" -i /var/mobile/cockpit.deb',
    'rm -f /var/mobile/cockpit.deb',
    'ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/Cockpit.dylib'
) -join '; '
Invoke-Ssh $install

if (-not $NoRespring) {
    Write-Step 'Respiring SpringBoard'
    Invoke-Ssh 'killall -9 SpringBoard || /var/jb/usr/bin/killall -9 SpringBoard'
    Write-Step "Waiting ${Wait}s for SpringBoard and the tweak"
    Start-Sleep -Seconds $Wait
}

Write-Step "Log: $remoteLog"
$logCommand = if ($Tail -gt 0) { "tail -n $Tail $remoteLog" } else { "cat $remoteLog" }
Invoke-Ssh $logCommand

if ($SaveLog) {
    & scp @sshOptions "${target}:$remoteLog" $SaveLog
    Write-Step "Saved to $SaveLog"
}
