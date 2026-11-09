#Requires -Version 5.1
<#
.SYNOPSIS
    One-command installer for Community Claude Code ("Claude Opus 5.5" in Claude Desktop).

.DESCRIPTION
    Downloads the CCC launcher and shim from GitHub, then installs Claude Desktop, uv,
    OpenCode, and the Community Claude Code server, applies the patches, starts the local
    shim, and connects Claude Desktop. No signup, API key, or account required.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/theRizwan/community-claude-code/main/bootstrap.ps1 | iex"

.EXAMPLE
    # Install only (do not start services yet)
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/theRizwan/community-claude-code/main/bootstrap.ps1))) -NoStart
#>
[CmdletBinding()]
param(
    [switch] $NoStart,
    [string] $RawBase = "https://raw.githubusercontent.com/theRizwan/community-claude-code/main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Work = Join-Path $env:LOCALAPPDATA "CCC\bootstrap"
New-Item -ItemType Directory -Force -Path $Work | Out-Null

Write-Host "==> Community Claude Code bootstrap" -ForegroundColor Cyan
Write-Host "==> Downloading launcher files to $Work"
foreach ($file in @("ccc.ps1", "ccc.cmd", "shim.py", "patch_ccc.py")) {
    Invoke-RestMethod -Uri "$RawBase/shim/$file" -OutFile (Join-Path $Work $file)
}
Write-Host "  OK  launcher files downloaded" -ForegroundColor Green

$launcher = Join-Path $Work "ccc.ps1"

Write-Host "==> Installing prerequisites (Claude Desktop, uv, OpenCode, Community Claude Code)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher setup
if ($LASTEXITCODE -ne 0) { throw "Setup failed with exit code $LASTEXITCODE" }

if (-not $NoStart) {
    Write-Host "==> Starting services and connecting Claude Desktop"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher start
    if ($LASTEXITCODE -ne 0) { throw "Start failed with exit code $LASTEXITCODE" }
}

Write-Host ""
Write-Host "Done. Open Claude Desktop and choose 'Claude Opus 5.5' in the model picker." -ForegroundColor Green
Write-Host "Manage later with: $launcher <setup|start|stop|restart|connect|disconnect|status|logs|help>"
