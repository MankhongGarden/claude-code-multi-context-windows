# Move Claude Desktop VM bundles from C: to D: via Junction
# This frees ~12 GB on C: drive
#
# REQUIREMENTS BEFORE RUNNING:
# 1. Close Claude Desktop completely (no Claude.exe in Task Manager)
# 2. Run this from an EXTERNAL PowerShell window (not from Claude session)
# 3. Wait for Hyper-V/WSL to release VHDX files (~30 sec after closing Desktop)
#
# USAGE:
#   pwsh -File .\scripts\move-vm-bundles.ps1
#
# ROLLBACK:
#   pwsh -File .\scripts\move-vm-bundles.ps1 -Rollback

[CmdletBinding()]
param(
    [switch]$Rollback,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$src    = "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\vm_bundles"
$dst    = "D:\ClaudeData\vm_bundles"
$backup = "D:\ClaudeData\vm_bundles.staging"

function Test-ClaudeRunning {
    $procs = Get-Process -Name "claude*","Code","electron" -ErrorAction SilentlyContinue |
             Where-Object { $_.MainWindowTitle -like "*Claude*" -or $_.Path -like "*Claude_pzs8sxrjxfjjc*" }
    return $procs.Count -gt 0
}

function Test-FileLock {
    param([string]$Path)
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

# === ROLLBACK PATH ===
if ($Rollback) {
    Write-Host "=== ROLLBACK MODE ===" -ForegroundColor Yellow
    if (Test-ClaudeRunning) {
        Write-Error "Claude Desktop is running. Close it first."
        exit 1
    }
    $item = Get-Item $src -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq "Junction") {
        Write-Host "Removing junction at $src..."
        Remove-Item -Path $src -Force
    }
    if (-not (Test-Path $src) -and (Test-Path $dst)) {
        Write-Host "Moving $dst back to $src..."
        Move-Item -Path $dst -Destination $src -Force
        Write-Host "ROLLBACK_OK"
    } else {
        Write-Error "Cannot rollback: src exists or dst missing"
        exit 1
    }
    exit 0
}

# === NORMAL MOVE PATH ===
Write-Host "=== Claude VM Bundles Mover ===" -ForegroundColor Cyan

# Pre-flight checks
Write-Host "`n[1/6] Checking Claude Desktop is not running..."
if (Test-ClaudeRunning) {
    Write-Error "Claude Desktop is still running. Close it completely (check Task Manager) and wait 30 seconds for Hyper-V to release VHDX files."
    exit 1
}

Write-Host "[2/6] Checking source folder exists..."
if (-not (Test-Path $src)) {
    Write-Error "Source folder not found: $src"
    exit 1
}

$existingItem = Get-Item $src -Force -ErrorAction SilentlyContinue
if ($existingItem -and $existingItem.LinkType -eq "Junction") {
    Write-Host "Source is ALREADY a junction (to: $($existingItem.Target)). Migration likely already done."
    if (-not $Force) { exit 0 }
}

Write-Host "[3/6] Checking VHDX files are not locked..."
$vhdxFiles = Get-ChildItem -Path $src -Filter "*.vhdx" -ErrorAction SilentlyContinue
foreach ($file in $vhdxFiles) {
    if (Test-FileLock $file.FullName) {
        Write-Error "File still locked: $($file.FullName) - wait longer or restart Windows"
        exit 1
    }
}
Write-Host "  All VHDX files unlocked. OK."

# Calculate size for progress estimate
$srcSize = (Get-ChildItem -Path $src -Recurse -File | Measure-Object Length -Sum).Sum / 1GB
Write-Host "[4/6] Source size: $([math]::Round($srcSize, 2)) GB"

# Disk space check
$dDrive = Get-PSDrive D
if ($dDrive.Free / 1GB -lt ($srcSize + 1)) {
    Write-Error "D: drive insufficient space. Need $([math]::Round($srcSize + 1, 2)) GB, have $([math]::Round($dDrive.Free / 1GB, 2)) GB"
    exit 1
}

# Move using Move-Item (same-volume is atomic; cross-volume is copy+delete)
Write-Host "[5/6] Moving $src to $dst (this may take 5-15 minutes for 12 GB)..."
Move-Item -Path $src -Destination $dst -Force
Write-Host "  Move complete."

Write-Host "[6/6] Creating junction $src -> $dst..."
New-Item -ItemType Junction -Path $src -Target $dst | Out-Null

# Verify
$jct = Get-Item $src -Force
if ($jct.LinkType -ne "Junction") {
    Write-Error "Junction creation failed - source folder restored manually needed"
    exit 1
}

Write-Host "`n=== SUCCESS ===" -ForegroundColor Green
Write-Host "  Junction: $src"
Write-Host "  Target:   $($jct.Target)"
Write-Host "  Freed:    ~$([math]::Round($srcSize, 2)) GB on C:"
Write-Host "`nVerify on disk:"
$cDrive = Get-PSDrive C
$dDrive = Get-PSDrive D
Write-Host "  C: Free $([math]::Round($cDrive.Free / 1GB, 1)) GB / Total $([math]::Round(($cDrive.Free + $cDrive.Used) / 1GB, 1)) GB"
Write-Host "  D: Free $([math]::Round($dDrive.Free / 1GB, 1)) GB / Total $([math]::Round(($dDrive.Free + $dDrive.Used) / 1GB, 1)) GB"
Write-Host "`nYou can now reopen Claude Desktop. First sandbox command will mount rootfs.vhdx from D:."
