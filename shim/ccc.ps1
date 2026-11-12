#requires -Version 5.1
<#
.SYNOPSIS
  Opus 5.5 for Claude Desktop: free OpenCode models, no signup or API key.

.DESCRIPTION
  Starts a local shim backed by `opencode serve`, starts Community Claude Code (CCC),
  and points Claude Desktop at it. The model picker shows one extra entry named
  exactly "Opus 5.5".

  Commands:
    setup       Install/repair Claude Desktop, Community Claude Code, and the patches.
    start       Start the shim and CCC, then connect Claude Desktop if needed.
    stop        Stop the shim and CCC (leaves Claude Desktop config alone).
    restart     stop + start.
    connect     Point Claude Desktop at the running shim/CCC setup.
    disconnect  Restore the Claude Desktop config saved before connect.
    status      Show ports, health, and Claude Desktop connection state.
    logs        Tail the shim and opencode logs.
    help        Show this text.

  Run with:  powershell -ExecutionPolicy Bypass -File .\ccc.ps1 <command>
  Or use the included ccc.cmd wrapper.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("setup", "start", "stop", "restart", "connect", "disconnect", "status", "logs", "help")]
    [string]$Command = "status",

    [string]$RepoPath,
    [int]$ShimPort = 0,
    [int]$OpencodePort = 0,
    [int]$CccPort = 0,
    [string]$BackendModel,
    [switch]$NoLaunch,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$script:__shimEntered = $false

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:LOCALAPPDATA "CCC"
$ConfigPath = Join-Path $ConfigDir "config.json"
$StatePath = Join-Path $ConfigDir "state.json"
$BackupDir = Join-Path $ConfigDir "backup"
$LatestBackupPath = Join-Path $BackupDir "latest.txt"
$ShimLog = Join-Path $ConfigDir "shim.log"
$OpencodeLog = Join-Path $ConfigDir "opencode-serve.log"

$BackendChain = @(
    "opencode/big-pickle",
    "opencode/pulse-alpha-free",
    "opencode/glm-5.3-flash-free",
    "opencode/deepseek-v4.1-flash-free",
    "opencode/mimo-v2.6-flash-free",
    "opencode/flint-40b-free",
    "opencode/nemotron-3.5-lightning-free",
    "opencode/nemotron-3.5-super-vl-free",
    "opencode/crouton-alpha-free",
    "opencode/beam-free"
) -join ","

$Defaults = [ordered]@{
    shimPort       = 4097
    opencodePort   = 4096
    cccPort        = 8082
    publicModel    = "opus-5.5"
    displayName    = "Claude Opus 5.5"
    backendModel   = $BackendChain
    token          = ""
    providerId     = ""
    cccProfileId   = ""
    repoPath       = ""
    pythonPath     = ""
    cccServerPath  = ""
    shimPath       = ""
    opencodeBin    = ""
}

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "  OK  $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "  !!  $Message" -ForegroundColor Yellow
}

function Fail([string]$Message) {
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-JsonFile([string]$Path, $Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-StringHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-Token {
    return "ccc-" + ([guid]::NewGuid().ToString("N"))
}

function Get-ProviderId {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("opencode-opus-5.5")
        $hash = $md5.ComputeHash($bytes)
        $hex = ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
        return "custom_$hex"
    } finally {
        $md5.Dispose()
    }
}

function Find-FirstFile([string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return ""
}

function Find-CommandPath([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return ""
}

function Resolve-Paths($Config) {
    $repoCandidates = @(
        $RepoPath,
        $Config.repoPath,
        (Join-Path (Split-Path -Parent $ScriptDir) "community-claude-code")
    )
    $repo = ""
    foreach ($candidate in $repoCandidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate "pyproject.toml"))) {
            $repo = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }

    $shimCandidates = @(
        $Config.shimPath,
        (Join-Path $ScriptDir "shim.py"),
        (Join-Path $repo "shim.py")
    )
    $shim = Find-FirstFile $shimCandidates

    $pythonCandidates = @(
        $Config.pythonPath,
        (Join-Path $env:APPDATA "uv\tools\community-claude-code\Scripts\python.exe"),
        (Find-CommandPath "python.exe"),
        (Find-CommandPath "python")
    )
    $python = Find-FirstFile $pythonCandidates

    $cccCandidates = @(
        $Config.cccServerPath,
        (Join-Path $env:USERPROFILE ".local\bin\ccc-server.exe"),
        (Find-CommandPath "ccc-server.exe")
    )
    $ccc = Find-FirstFile $cccCandidates

    $opencodeCandidates = @(
        $Config.opencodeBin,
        (Find-CommandPath "opencode.exe"),
        (Find-CommandPath "opencode.cmd"),
        (Find-CommandPath "opencode"),
        "C:\nvm4w\nodejs\node_modules\opencode-ai\bin\opencode.exe"
    )
    $opencode = ""
    foreach ($candidate in $opencodeCandidates) {
        if (-not $candidate) { continue }
        $extension = [System.IO.Path]::GetExtension($candidate).ToLowerInvariant()
        if ($extension -in @(".ps1", ".sh")) { continue }
        if ($extension -eq ".cmd") {
            $resolved = Join-Path (Split-Path -Parent $candidate) "node_modules\opencode-ai\bin\opencode.exe"
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                $opencode = (Resolve-Path -LiteralPath $resolved).Path
                break
            }
            continue
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $opencode = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }

    return [pscustomobject]@{
        Repo       = $repo
        Shim       = $shim
        Python     = $python
        CccServer  = $ccc
        Opencode   = $opencode
    }
}

function Get-Config {
    $config = [ordered]@{}
    foreach ($key in $Defaults.Keys) { $config[$key] = $Defaults[$key] }

    $loaded = Read-JsonFile $ConfigPath
    if ($loaded) {
        foreach ($key in $Defaults.Keys) {
            $property = $loaded.PSObject.Properties[$key]
            if ($property -and $null -ne $property.Value -and "$($property.Value)" -ne "") {
                $config[$key] = $property.Value
            }
        }
        $profile = $loaded.PSObject.Properties["cccProfileId"]
        if ($profile) { $config["cccProfileId"] = $profile.Value }
    }

    $paths = Resolve-Paths $config
    if ($paths.Repo) { $config["repoPath"] = $paths.Repo }
    if ($paths.Shim) { $config["shimPath"] = $paths.Shim }
    if ($paths.Python) { $config["pythonPath"] = $paths.Python }
    if ($paths.CccServer) { $config["cccServerPath"] = $paths.CccServer }
    if ($paths.Opencode) { $config["opencodeBin"] = $paths.Opencode }

    if (-not $config["token"]) {
        $envPath = Get-CccEnvPath
        if (Test-Path -LiteralPath $envPath) {
            foreach ($line in Get-Content -LiteralPath $envPath) {
                if ($line -match '^\s*ANTHROPIC_AUTH_TOKEN\s*=\s*(ccc-[0-9a-f]+)\s*$') {
                    $config["token"] = $matches[1]
                    break
                }
            }
        }
    }
    if (-not $config["token"]) { $config["token"] = New-Token }
    if (-not $config["providerId"]) { $config["providerId"] = Get-ProviderId }

    if ($ShimPort -gt 0) { $config["shimPort"] = $ShimPort }
    if ($OpencodePort -gt 0) { $config["opencodePort"] = $OpencodePort }
    if ($CccPort -gt 0) { $config["cccPort"] = $CccPort }
    if ($BackendModel) { $config["backendModel"] = $BackendModel }

    return $config
}

function Save-Config($Config) {
    Write-JsonFile $ConfigPath $Config
}

function Test-PortFree([int]$Port) {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

function Select-FreePort([int]$Preferred) {
    if ($Preferred -gt 0 -and (Test-PortFree $Preferred)) { return $Preferred }
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return [int]$listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Get-Json([string]$Url, [int]$Timeout = 4) {
    try {
        return Invoke-RestMethod -Uri $Url -TimeoutSec $Timeout -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-ListeningPid([int]$Port) {
    $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($connection) { return [int]$connection.OwningProcess }
    return 0
}

function Wait-ForHealth([string]$Url, [scriptblock]$IsHealthy, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $payload = Get-Json $Url 2
        if ($payload -and (& $IsHealthy $payload)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Stop-ProcessTree([int]$ProcessId) {
    if ($ProcessId -le 0) { return }
    try {
        & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
    } catch {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-ByPort([int]$Port) {
    $owned = Get-ListeningPid $Port
    if ($owned -gt 0) {
        Stop-ProcessTree $owned
        Start-Sleep -Milliseconds 500
    }
}

function Get-ClaudeConfigRoot {
    $local = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path -LiteralPath $local) {
        $packaged = Get-ChildItem -LiteralPath $local -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidate = Join-Path $_.FullName "LocalCache\Local\Claude-3p"
                if (Test-Path -LiteralPath $candidate) { $candidate }
            } | Select-Object -First 1
        if ($packaged) { return $packaged }
    }
    $fallback = Join-Path $env:LOCALAPPDATA "Claude-3p"
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return ""
}

function Get-ClaudePackage {
    try {
        return Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*Claude*" -and $_.PackageFamilyName -like "Claude_*" } |
            Sort-Object Version -Descending |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Get-ClaudeExecutable {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude\claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Claude\claude.exe"),
        (Join-Path $env:PROGRAMFILES "Claude\claude.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Claude\claude.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return ""
}

function Test-ClaudeRunning {
    $root = Get-ClaudeConfigRoot
    $processes = Get-CimInstance Win32_Process -Filter "name='Claude.exe'" -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        if ($process.ExecutablePath -and $process.ExecutablePath -like "*WindowsApps\Claude_*") { return $true }
        if ($process.CommandLine -and $process.CommandLine -notlike "*--type=*") { return $true }
    }
    return $false
}

function Stop-ClaudeDesktop {
    Write-Step "Closing Claude Desktop"
    $stopped = $false
    $processes = Get-CimInstance Win32_Process -Filter "name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like "*WindowsApps\Claude_*" }
    foreach ($process in $processes) {
        if ($process.CommandLine -and $process.CommandLine -notlike "*--type=*") {
            try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; $stopped = $true } catch { }
        }
    }
    Start-Sleep -Seconds 4
    $remaining = Get-CimInstance Win32_Process -Filter "name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -like "*WindowsApps\Claude_*" }
    foreach ($process in $remaining) {
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; $stopped = $true } catch { }
    }
    if ($stopped) { Start-Sleep -Seconds 2 }
    Write-Ok "Claude Desktop is closed"
}

function Start-ClaudeDesktop {
    if ($NoLaunch) {
        Write-Warn "Skipping Claude Desktop launch (-NoLaunch)"
        return
    }
    Write-Step "Launching Claude Desktop"
    $package = Get-ClaudePackage
    if ($package) {
        $aumid = "$($package.PackageFamilyName)!Claude"
        try {
            Start-Process "shell:AppsFolder\$aumid"
            Write-Ok "Launched $aumid"
            return
        } catch {
            Write-Warn "Could not launch MSIX app: $($_.Exception.Message)"
        }
    }
    $exe = Get-ClaudeExecutable
    if ($exe) {
        Start-Process -FilePath $exe
        Write-Ok "Launched $exe"
        return
    }
    Write-Warn "Claude Desktop executable not found; run: .\ccc.ps1 setup"
}

function Get-CccEnvPath {
    return (Join-Path $env:USERPROFILE ".ccc\.env")
}

function Write-CccEnv($Config) {
    $envPath = Get-CccEnvPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $envPath) | Out-Null

    $existing = @{}
    if (Test-Path -LiteralPath $envPath) {
        foreach ($line in Get-Content -LiteralPath $envPath) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
                $existing[$matches[1]] = $matches[2]
            }
        }
    }

    $providers = @()
    if ($existing.ContainsKey("CCC_CUSTOM_PROVIDERS") -and $existing["CCC_CUSTOM_PROVIDERS"]) {
        try {
            $parsed = $existing["CCC_CUSTOM_PROVIDERS"] | ConvertFrom-Json
            if ($parsed) { $providers = @($parsed) }
        } catch {
            $providers = @()
        }
    }
    $providers = @($providers | Where-Object { $_ -and $_.provider_id -ne $Config.providerId })

    $modelRef = "$($Config.providerId)/$($Config.publicModel)"
    $provider = [ordered]@{
        provider_id      = $Config.providerId
        display_name     = $Config.displayName
        base_url         = "http://127.0.0.1:$($Config.shimPort)/v1"
        api_keys         = @("opencode")
        api_format       = "openai_chat"
        reasoning_format = "provider_default"
        model_ids        = @($Config.publicModel)
    }
    $providers += $provider

    $existing["CCC_CONFIG_SCHEMA"] = "2"
    $existing["CCC_OPEN_BROWSER"] = "false"
    $existing["HOST"] = "127.0.0.1"
    $existing["PORT"] = "$($Config.cccPort)"
    $existing["PROXY_AUTH_ENABLED"] = "true"
    $existing["ANTHROPIC_AUTH_TOKEN"] = "$($Config.token)"
    $existing["HTTP_READ_TIMEOUT"] = "300"
    $existing["MODEL"] = $modelRef
    $existing["MODEL_FABLE"] = $modelRef
    $existing["MODEL_OPUS"] = $modelRef
    $existing["MODEL_SONNET"] = $modelRef
    $existing["MODEL_HAIKU"] = $modelRef
    $existing["CCC_CUSTOM_PROVIDERS"] = (ConvertTo-Json -InputObject @($providers) -Depth 20 -Compress)

    $lines = @(
        "# Managed by Community Claude Code.",
        "# Generated by the CCC launcher. Edit settings in /admin when possible.",
        ""
    )
    foreach ($key in ($existing.Keys | Sort-Object)) {
        $lines += "$key=$($existing[$key])"
    }
    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($envPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $content
}

function Get-EnvHash([string]$Content) {
    return Get-StringHash $Content
}

function Get-State {
    $state = Read-JsonFile $StatePath
    if (-not $state) { return $null }
    return $state
}

function Save-State($State) {
    Write-JsonFile $StatePath $State
}

function Ensure-State($State) {
    if (-not $State) { $State = [pscustomobject]@{} }
    foreach ($pair in @(
        @("shimPid", 0),
        @("cccPid", 0),
        @("envHash", ""),
        @("shimPort", 0),
        @("opencodePort", 0),
        @("cccPort", 0)
    )) {
        if (-not ($State.PSObject.Properties[$pair[0]])) {
            $State | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
    }
    return $State
}

function Start-Shim($Config, $State) {
    if ($script:__shimEntered) {
        Write-Host "SHIM RE-ENTRY CALLSTACK:" -ForegroundColor Red
        Get-PSCallStack | ForEach-Object { Write-Host "  $($_.Command) @ line $($_.ScriptLineNumber)" -ForegroundColor Red }
        Fail "Start-Shim re-entered; aborting"
    }
    $script:__shimEntered = $true
    try {
        $State = Ensure-State $State
        $healthUrl = "http://127.0.0.1:$($Config.shimPort)/health"
        $health = Get-Json $healthUrl 2
        if ($health -and $health.ok -eq $true) {
            $state.shimPid = Get-ListeningPid $Config.shimPort
            Write-Ok "Shim already running on port $($Config.shimPort) (pid $($state.shimPid))"
            return
        }

        Stop-ByPort $Config.shimPort
        if (-not $Config.shimPath) { Fail "shim.py not found. Run setup." }
        if (-not $Config.pythonPath) { Fail "Python not found. Run setup." }

        $Config.shimPort = Select-FreePort $Config.shimPort
        $Config.opencodePort = Select-FreePort $Config.opencodePort

        Write-Step "Starting shim on port $($Config.shimPort) (opencode $($Config.opencodePort))"
        $argumentList = @(
            "`"$($Config.shimPath)`"",
            "--shim-port", "$($Config.shimPort)",
            "--opencode-port", "$($Config.opencodePort)",
            "--backend-model", "$($Config.backendModel)",
            "--public-model", "$($Config.publicModel)",
            "--log-file", "`"$ShimLog`"",
            "--verbose"
        )
        if ($Config.opencodeBin) {
            $argumentList += @("--opencode-bin", "`"$($Config.opencodeBin)`"")
        }
        $process = Start-Process -FilePath $Config.pythonPath -ArgumentList $argumentList -PassThru -WindowStyle Hidden
        $state.shimPid = $process.Id
        $healthy = Wait-ForHealth $healthUrl { param($p) $p.ok -eq $true } 60
        if (-not $healthy) {
            $tail = ""
            if (Test-Path -LiteralPath $ShimLog) { $tail = (Get-Content -LiteralPath $ShimLog -Tail 25 -ErrorAction SilentlyContinue) -join "`n" }
            Stop-ProcessTree $process.Id
            Fail "Shim did not become healthy.`n$tail"
        }
        Write-Ok "Shim is healthy on port $($Config.shimPort)"
    } finally {
        $script:__shimEntered = $false
    }
}

function Start-Ccc($Config, $State) {
    $State = Ensure-State $State
    $healthUrl = "http://127.0.0.1:$($Config.cccPort)/health"
    $health = Get-Json $healthUrl 2

    if ($health -and $health.status -eq "healthy") {
        $currentEnv = Write-CccEnv $Config
        $currentHash = Get-EnvHash $currentEnv
        if ($State.envHash -and $State.envHash -eq $currentHash) {
            $State.cccPid = Get-ListeningPid $Config.cccPort
            Write-Ok "CCC already running on port $($Config.cccPort) (pid $($State.cccPid))"
            return
        }
        Write-Step "CCC configuration changed; restarting CCC"
        Stop-ByPort $Config.cccPort
    } else {
        Stop-ByPort $Config.cccPort
    }

    if (-not $Config.cccServerPath) { Fail "ccc-server.exe not found. Run setup." }

    $Config.cccPort = Select-FreePort $Config.cccPort
    $envContent = Write-CccEnv $Config
    $envHash = Get-EnvHash $envContent

    Write-Step "Starting Community Claude Code on port $($Config.cccPort)"
    $workingDir = $Config.repoPath
    if (-not $workingDir) { $workingDir = $ScriptDir }
    $process = Start-Process -FilePath $Config.cccServerPath -PassThru -WindowStyle Hidden -WorkingDirectory $workingDir
    $State.cccPid = $process.Id
    $State.envHash = $envHash
    $healthy = Wait-ForHealth $healthUrl { param($p) $p.status -eq "healthy" } 45
    if (-not $healthy) {
        Stop-ProcessTree $process.Id
        Fail "Community Claude Code did not become healthy. Check $env:USERPROFILE\.ccc\logs\server.log"
    }
    Write-Ok "CCC is healthy on port $($Config.cccPort)"
}

function Get-ClaudeMeta([string]$Root) {
    return Read-JsonFile (Join-Path $Root "configLibrary\_meta.json")
}

function Get-CccProfileId($Config, [string]$Root) {
    $meta = Get-ClaudeMeta $Root
    if ($meta -and $meta.entries) {
        $entry = $meta.entries | Where-Object { $_.name -eq "CCC" } | Select-Object -First 1
        if ($entry) { return [string]$entry.id }
    }
    return [string]$Config.cccProfileId
}

function Test-ClaudeConnected($Config, [string]$Root) {
    if (-not $Root) { return $false }
    $meta = Get-ClaudeMeta $Root
    if (-not $meta) { return $false }
    $cccId = Get-CccProfileId $Config $Root
    if (-not $cccId) { return $false }
    return ([string]$meta.appliedId -eq $cccId)
}

function Backup-ClaudeConfig([string]$Root, $Config) {
    if (-not $Root) { Fail "Claude Desktop config directory not found. Launch Claude Desktop once, quit it, and retry." }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $destination = Join-Path $BackupDir $stamp
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    $metaPath = Join-Path $Root "configLibrary\_meta.json"
    $meta = Read-JsonFile $metaPath
    $appliedId = ""
    $entries = @()
    if ($meta) {
        $appliedId = [string]$meta.appliedId
        $entries = $meta.entries
    }

    Copy-Item -LiteralPath $metaPath -Destination (Join-Path $destination "_meta.json") -Force
    $desktopPath = Join-Path $Root "claude_desktop_config.json"
    if (Test-Path -LiteralPath $desktopPath) {
        Copy-Item -LiteralPath $desktopPath -Destination (Join-Path $destination "claude_desktop_config.json") -Force
    }
    if ($appliedId) {
        $profilePath = Join-Path $Root "configLibrary\$appliedId.json"
        if (Test-Path -LiteralPath $profilePath) {
            Copy-Item -LiteralPath $profilePath -Destination (Join-Path $destination "applied-profile.json") -Force
        }
    }

    $record = [ordered]@{
        timestamp = $stamp
        root      = $Root
        appliedId = $appliedId
        entries   = $entries
    }
    Write-JsonFile (Join-Path $destination "backup.json") $record
    [System.IO.File]::WriteAllText($LatestBackupPath, $destination, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "Backed up Claude Desktop config to $destination"
    return $destination
}

function Remove-CccProfiles([string]$Root, $Config) {
    $configLibrary = Join-Path $Root "configLibrary"
    if (-not (Test-Path -LiteralPath $configLibrary)) { return }
    $meta = Get-ClaudeMeta $Root
    if ($meta -and $meta.entries) {
        foreach ($entry in $meta.entries) {
            if ($entry.name -in @("FCC", "CCC")) {
                $path = Join-Path $configLibrary "$($entry.id).json"
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $configLibrary -Filter "*.json" -ErrorAction SilentlyContinue) {
        if ($file.Name -eq "_meta.json") { continue }
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        } catch {
            continue
        }
        if ($profile.inferenceGatewayBaseUrl -and $profile.inferenceGatewayApiKey -eq $Config.token) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-ClaudeConfig($Config) {
    $backup = ""
    if (Test-Path -LiteralPath $LatestBackupPath) {
        $backup = (Get-Content -LiteralPath $LatestBackupPath -Raw).Trim()
    }
    if (-not $backup -or -not (Test-Path -LiteralPath $backup)) {
        Write-Warn "No Claude Desktop backup found; leaving config unchanged"
        return
    }
    $root = Get-ClaudeConfigRoot
    if (-not $root) { Fail "Claude Desktop config directory not found" }

    $metaBackup = Join-Path $backup "_meta.json"
    if (Test-Path -LiteralPath $metaBackup) {
        Copy-Item -LiteralPath $metaBackup -Destination (Join-Path $root "configLibrary\_meta.json") -Force
    }
    $desktopBackup = Join-Path $backup "claude_desktop_config.json"
    if (Test-Path -LiteralPath $desktopBackup) {
        Copy-Item -LiteralPath $desktopBackup -Destination (Join-Path $root "claude_desktop_config.json") -Force
    }
    Remove-CccProfiles $root $Config
    foreach ($legacy in @(
        (Join-Path $env:USERPROFILE ".ccc\claude-desktop-disconnect.json"),
        (Join-Path $env:USERPROFILE ".fcc\claude-desktop-disconnect.json")
    )) {
        if (Test-Path -LiteralPath $legacy) {
            Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Restored Claude Desktop config from $backup"
}

function Connect-ClaudeDesktop($Config, $State) {
    $root = Get-ClaudeConfigRoot
    if (-not $root) {
        Fail "Claude Desktop config directory not found. Install/launch Claude Desktop once, then retry."
    }

    $wasRunning = Test-ClaudeRunning
    if ($wasRunning) { Stop-ClaudeDesktop }

    if (-not (Test-ClaudeConnected $Config $root)) {
        $meta = Get-ClaudeMeta $root
        $appliedEntry = $null
        if ($meta -and $meta.entries) {
            $appliedEntry = $meta.entries | Where-Object { $_.id -eq $meta.appliedId } | Select-Object -First 1
        }
        if ($appliedEntry -and $appliedEntry.name -in @("FCC", "CCC")) {
            Write-Ok "Claude Desktop already points at a managed profile; keeping the existing backup"
        } else {
            Backup-ClaudeConfig $root $Config | Out-Null
        }
    } else {
        Write-Ok "Claude Desktop is already connected"
    }

    Write-Step "Connecting Claude Desktop to Community Claude Code"
    $connectUrl = "http://127.0.0.1:$($Config.cccPort)/admin/api/integrations/claude-desktop/connect"
    try {
        $response = Invoke-RestMethod -Uri $connectUrl -Method Post -TimeoutSec 60 -ErrorAction Stop
    } catch {
        $detail = ""
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        Fail "Connect failed: $($_.Exception.Message) $detail"
    }
    if ($response.connected -ne $true) {
        Fail "CCC did not report a successful connection: $($response | ConvertTo-Json -Compress)"
    }

    $cccId = Get-CccProfileId $Config $root
    if ($cccId) {
        $Config.cccProfileId = $cccId
        Save-Config $Config
    }
    Write-Ok "Claude Desktop now uses the CCC gateway on port $($Config.cccPort)"

    if ($wasRunning -or -not $NoLaunch) { Start-ClaudeDesktop }
}

function Disconnect-ClaudeDesktop($Config) {
    $root = Get-ClaudeConfigRoot
    if (-not $root) { Fail "Claude Desktop config directory not found" }
    $wasRunning = Test-ClaudeRunning
    if ($wasRunning) { Stop-ClaudeDesktop }
    Restore-ClaudeConfig $Config
    if ($wasRunning -or -not $NoLaunch) { Start-ClaudeDesktop }
}

function Stop-All($Config) {
    Write-Step "Stopping Community Claude Code services"
    $state = Get-State
    if ($state -and $state.cccPid) { Stop-ProcessTree ([int]$state.cccPid) }
    if ($state -and $state.shimPid) { Stop-ProcessTree ([int]$state.shimPid) }
    Stop-ByPort $Config.cccPort
    Stop-ByPort $Config.shimPort
    Stop-ByPort $Config.opencodePort
    Write-Ok "Services stopped"
}

function Show-Status($Config) {
    $shim = Get-Json "http://127.0.0.1:$($Config.shimPort)/health" 2
    $ccc = Get-Json "http://127.0.0.1:$($Config.cccPort)/health" 2
    $root = Get-ClaudeConfigRoot
    $connected = Test-ClaudeConnected $Config $root
    $running = Test-ClaudeRunning

    Write-Host ""
    Write-Host "Opus 5.5 status" -ForegroundColor White
    Write-Host "  shim       http://127.0.0.1:$($Config.shimPort)  $(if ($shim -and $shim.ok) { 'healthy' } else { 'down' })"
    Write-Host "  opencode   http://127.0.0.1:$($Config.opencodePort)  $(if ($shim -and $shim.opencode) { 'healthy' } else { 'down' })"
    Write-Host "  CCC        http://127.0.0.1:$($Config.cccPort)  $(if ($ccc -and $ccc.status -eq 'healthy') { 'healthy' } else { 'down' })"
    Write-Host "  backend    $($Config.backendModel)"
    Write-Host "  model      $($Config.displayName)  ($($Config.publicModel))"
    Write-Host "  Desktop    $(if ($running) { 'running' } else { 'not running' }), $(if ($connected) { 'connected to CCC' } else { 'not connected' })"
    if ($root) { Write-Host "  config     $root" }
    Write-Host ""

    if ($ccc -and $ccc.status -eq "healthy") {
        $headers = @{ Authorization = "Bearer $($Config.token)"; "X-CCC-Model-View" = "claude-desktop" }
        try {
            $models = Invoke-RestMethod -Uri "http://127.0.0.1:$($Config.cccPort)/v1/models" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            $entry = $models.data | Where-Object { $_.display_name -eq $Config.displayName } | Select-Object -First 1
            if ($entry) {
                Write-Ok "Picker entry: $($entry.display_name) -> $($entry.id)"
            } else {
                Write-Warn "Picker entry '$($Config.displayName)' was not found in the CCC catalog"
            }
        } catch {
            Write-Warn "Could not read the CCC model catalog: $($_.Exception.Message)"
        }
    }
}

function Ensure-OpenCode {
    $existing = Find-CommandPath "opencode.exe"
    if ($existing) { return $existing }

    $cmdShim = Find-CommandPath "opencode.cmd"
    if ($cmdShim) {
        $resolved = Join-Path (Split-Path -Parent $cmdShim) "node_modules\opencode-ai\bin\opencode.exe"
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return (Resolve-Path -LiteralPath $resolved).Path
        }
    }

    $npm = Find-CommandPath "npm.cmd"
    if (-not $npm) { $npm = Find-CommandPath "npm" }
    if ($npm) {
        Write-Step "Installing OpenCode via npm"
        & $npm install -g opencode-ai 2>&1 | Out-Null
        $existing = Find-CommandPath "opencode.exe"
        if ($existing) { return $existing }
        $npmPrefix = (& $npm prefix -g 2>$null | Out-String).Trim()
        if ($npmPrefix) {
            $candidate = Join-Path $npmPrefix "node_modules\opencode-ai\bin\opencode.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }

    Write-Step "Downloading OpenCode"
    $architecture = $env:PROCESSOR_ARCHITECTURE
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    $assetName = if ($architecture -eq "ARM64") { "opencode-windows-arm64.zip" } else { "opencode-windows-x64-baseline.zip" }
    $release = Invoke-RestMethod -Uri "https://opencode.ai/update/api/latest/cli/npm"
    $version = $release.version
    if (-not $version) { Fail "Could not resolve the OpenCode version" }
    $archiveUrl = "https://opencode.ai/files/bin/$version/$assetName"
    $temporaryRoot = Join-Path $env:TEMP ("ccc-opencode-" + [guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
        $archivePath = Join-Path $temporaryRoot $assetName
        Invoke-RestMethod -Uri $archiveUrl -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryRoot -Force
        $executable = Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File -Filter "opencode.exe" |
            Select-Object -First 1
        if (-not $executable) { Fail "The OpenCode archive did not contain opencode.exe" }
        $installDirectory = Join-Path $env:USERPROFILE ".opencode\bin"
        New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
        $destination = Join-Path $installDirectory "opencode.exe"
        Copy-Item -LiteralPath $executable.FullName -Destination $destination -Force
        return $destination
    }
    finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Setup($Config) {
    Write-Step "Checking prerequisites"
    $winget = Find-CommandPath "winget.exe"
    if (-not $winget) { Fail "winget is required to install missing pieces" }

    $package = Get-ClaudePackage
    if (-not $package) {
        Write-Step "Installing Claude Desktop"
        & $winget install --id Anthropic.Claude -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Fail "winget could not install Claude Desktop" }
        $package = Get-ClaudePackage
        if (-not $package) { Fail "Claude Desktop is still not installed" }
    }
    Write-Ok "Claude Desktop $($package.Version)"

    $uv = Find-CommandPath "uv.exe"
    if (-not $uv) {
        $uv = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "uv.exe" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1 -Expand FullName
    }
    if (-not $uv) {
        Write-Step "Installing uv"
        & $winget install --id astral-sh.uv -e --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Fail "winget could not install uv" }
        $uv = Find-CommandPath "uv.exe"
        if (-not $uv) {
            $uv = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "uv.exe" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Select-Object -First 1 -Expand FullName
        }
        if (-not $uv) { Fail "uv is still not available; open a new terminal and retry" }
    }
    Write-Ok "uv $(& $uv --version)"

    $opencode = $Config.opencodeBin
    if (-not ($opencode -and $opencode.ToLowerInvariant().EndsWith(".exe") -and (Test-Path -LiteralPath $opencode -PathType Leaf))) {
        $opencode = Ensure-OpenCode
    }
    if (-not $opencode) { Fail "OpenCode could not be installed automatically" }
    Write-Ok "OpenCode $opencode"

    $repo = $Config.repoPath
    if (-not $repo) {
        $repo = Join-Path (Split-Path -Parent $ScriptDir) "community-claude-code"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repo "pyproject.toml"))) {
        $git = Find-CommandPath "git.exe"
        if (-not $git) {
            Write-Step "Installing git"
            & $winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
            $git = Find-CommandPath "git.exe"
            if (-not $git) {
                $git = Get-ChildItem "C:\Program Files\Git\cmd\git.exe" -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -Expand FullName
            }
        }
        if (-not $git) { Fail "Community Claude Code is missing and git is not installed" }
        Write-Step "Cloning Community Claude Code to $repo"
        & $git clone --depth 1 --branch main https://github.com/theRizwan/community-claude-code.git $repo
        if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
    }
    $Config.repoPath = (Resolve-Path -LiteralPath $repo).Path

    Write-Step "Installing Community Claude Code (editable)"
    & $uv python install 3.14.10
    & $uv tool install --editable $Config.repoPath --python 3.14.10 --force
    if ($LASTEXITCODE -ne 0) { Fail "uv tool install failed" }

    $paths = Resolve-Paths $Config
    $Config.pythonPath = $paths.Python
    $Config.cccServerPath = $paths.CccServer
    $Config.shimPath = $paths.Shim
    $Config.opencodeBin = $paths.Opencode
    if (-not $Config.pythonPath) { Fail "Could not find the CCC Python interpreter" }
    if (-not $Config.cccServerPath) { Fail "Could not find ccc-server.exe" }
    if (-not $Config.shimPath) { Fail "Could not find shim.py" }

    Write-Step "Applying Community Claude Code patches"
    $patcher = Join-Path $ScriptDir "patch_ccc.py"
    if (-not (Test-Path -LiteralPath $patcher)) { Fail "patch_ccc.py not found next to this script" }
    & $Config.pythonPath $patcher $Config.repoPath
    if ($LASTEXITCODE -ne 0) { Fail "patch_ccc.py failed" }

    Save-Config $Config
    Write-CccEnv $Config | Out-Null
    Write-Ok "Setup complete"
    Write-Host "Next: .\ccc.ps1 start" -ForegroundColor White
}

function Show-Logs {
    if (Test-Path -LiteralPath $ShimLog) {
        Write-Host "--- shim.log (tail) ---" -ForegroundColor Cyan
        Get-Content -LiteralPath $ShimLog -Tail 40
    } else {
        Write-Warn "No shim log yet"
    }
    if (Test-Path -LiteralPath $OpencodeLog) {
        Write-Host "--- opencode-serve.log (tail) ---" -ForegroundColor Cyan
        Get-Content -LiteralPath $OpencodeLog -Tail 40
    } else {
        Write-Warn "No opencode log yet"
    }
}

function Test-ClaudeProfileCurrent($Config) {
    $root = Get-ClaudeConfigRoot
    if (-not $root) { return $false }
    $cccId = Get-CccProfileId $Config $root
    if (-not $cccId) { return $false }
    $profile = Read-JsonFile (Join-Path $root "configLibrary\$cccId.json")
    if (-not $profile) { return $false }
    return (
        [string]$profile.inferenceGatewayApiKey -eq [string]$Config.token -and
        [string]$profile.inferenceGatewayBaseUrl -eq "http://127.0.0.1:$($Config.cccPort)"
    )
}

function Update-ClaudeProfile {
    Write-Step "Refreshing Claude Desktop gateway settings"
    $cccPort = (Get-Config).cccPort
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$cccPort/admin/api/integrations/claude-desktop/refresh" -Method Post -TimeoutSec 60 -ErrorAction Stop | Out-Null
        Write-Ok "Claude Desktop profile refreshed"
    } catch {
        Write-Warn "Could not refresh the Claude Desktop profile: $($_.Exception.Message)"
    }
}

function Start-All($Config) {
    $state = Ensure-State (Get-State)
    Start-Shim $Config $state
    Start-Ccc $Config $state
    $state.shimPort = $Config.shimPort
    $state.opencodePort = $Config.opencodePort
    $state.cccPort = $Config.cccPort
    Save-Config $Config
    Save-State $state

    $root = Get-ClaudeConfigRoot
    if (-not (Test-ClaudeConnected $Config $root)) {
        Connect-ClaudeDesktop $Config $state
    } elseif (-not (Test-ClaudeProfileCurrent $Config)) {
        Write-Warn "Claude Desktop points at an outdated gateway; refreshing it"
        Stop-ClaudeDesktop
        Update-ClaudeProfile
        Start-ClaudeDesktop
    } else {
        Write-Ok "Claude Desktop is already connected"
        if (-not (Test-ClaudeRunning)) { Start-ClaudeDesktop }
    }
    Show-Status $Config
}

function Show-Help {
    Write-Host ""
    Write-Host "Claude Opus 5.5 for Claude Desktop" -ForegroundColor White
    Write-Host ""
    Write-Host "  .\ccc.ps1 setup       Install/repair everything"
    Write-Host "  .\ccc.ps1 start       Start services and connect Claude Desktop"
    Write-Host "  .\ccc.ps1 stop        Stop services"
    Write-Host "  .\ccc.ps1 restart     Restart services"
    Write-Host "  .\ccc.ps1 connect     Connect Claude Desktop"
    Write-Host "  .\ccc.ps1 disconnect  Restore the pre-connect Claude Desktop config"
    Write-Host "  .\ccc.ps1 status      Show health and connection state"
    Write-Host "  .\ccc.ps1 logs        Tail the shim/opencode logs"
    Write-Host ""
    Write-Host "Options: -ShimPort 4097 -OpencodePort 4096 -CccPort 8082"
    Write-Host "         -BackendModel opencode/big-pickle -NoLaunch -Force"
    Write-Host ""
}

try {
    $config = Get-Config
    switch ($Command) {
        "setup" {
            Invoke-Setup $config
        }
        "start" {
            Start-All $config
        }
        "stop" {
            Stop-All $config
            $root = Get-ClaudeConfigRoot
            if (Test-ClaudeConnected $config $root) {
                Write-Warn "Claude Desktop still points at the stopped CCC gateway. Run .\ccc.ps1 disconnect to restore the previous profile."
            }
        }
        "restart" {
            Stop-All $config
            Start-Sleep -Seconds 1
            Start-All $config
        }
        "connect" {
            $state = Ensure-State (Get-State)
            Start-Shim $config $state
            Start-Ccc $config $state
            Save-Config $config
            Save-State $state
            Connect-ClaudeDesktop $config $state
            Show-Status $config
        }
        "disconnect" {
            Disconnect-ClaudeDesktop $config
        }
        "status" {
            Show-Status $config
        }
        "logs" {
            Show-Logs
        }
        "help" {
            Show-Help
        }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
