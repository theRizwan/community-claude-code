param(
    [switch] $VoiceLocal,
    [string] $TorchBackend = "",
    [switch] $RtkHeadroom,
    [switch] $DryRun,
    [switch] $Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]] $RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Filled from the selected release before installation; placeholders are for dry-run.
$PythonRequest = "<release-python>"
$MinUvVersion = "<release-uv-minimum>"
$CccRepoUrl = "https://github.com/theRizwan/community-claude-code"
$ClaudeInstallUrl = "https://claude.ai/install.ps1"
$CodexInstallUrl = "https://chatgpt.com/codex/install.ps1"
$PiInstallUrl = "https://pi.dev/install.ps1"
$OpenCodeReleaseBaseUrl = "https://opencode.ai/files/bin"
$script:OriginalOpenCodeSearchPath = ""
$HermesInstallUrl = "https://hermes-agent.nousresearch.com/install.ps1"
$DshMinimumVersion = "0.2.0-rc.2"
$DshPackage = "@deepseek-ai/dsh@latest"
$GrokInstallUrl = "https://x.ai/cli/install.ps1"
$MuseInstallUrl = "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install-muse.ps1"
$AgyInstallUrl = "https://antigravity.google/cli/install.ps1"
$AgyMinimumVersion = "1.4.7"
$RtkVersion = "0.44.2"
$HeadroomPackage = "headroom-ai[mcp]==0.40.0"
$RtkReleaseBaseUrl = "https://github.com/rtk-ai/rtk/releases/download/v$RtkVersion"
$RtkWindowsAssetName = "rtk-x86_64-pc-windows-msvc.zip"
$RtkWindowsAssetSha256 = "3a1e114edce9080f8a10663e9c87488363a82f14a5ca8aab2ad416817f89d47c"
$UvInstallUrl = "https://astral.sh/uv/install.ps1"
$script:InstallClaudeCode = $true
$script:InstallCodex = $false
$script:InstallPi = $false
$script:InstallOpenCode = $true
$script:InstallCline = $false
$script:InstallHermes = $false
$script:InstallDsh = $false
$script:InstallGrok = $false
$script:InstallMuse = $false
$script:InstallAider = $false
$script:InstallAgy = $false
$script:PiAvailable = $false
$script:MuseAvailable = $false
$script:EnableRtkHeadroom = $RtkHeadroom.IsPresent
$CccInstallVersion = [Environment]::GetEnvironmentVariable("CCC_INSTALL_VERSION")
$CccReleasePattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z'
$script:InstallLog = ""
$script:InstallLogWarning = $false
$script:InstallSteps = [ordered] @{}
$script:CurrentInstallStep = ""
$script:InstallStepOutcome = "Completed"
$script:InstallerPath = $PSCommandPath
$script:InstallStageNumber = 0
$script:InstallStageCount = 0
$script:CccVerified = $false
$script:DesktopReady = $false
$script:CccDesktopCommand = ""
$script:CccIconPath = ""
$script:HeadroomPath = ""
$CccCommands = @(
    # Include retired entry points so updates reject older CCC processes before replacement.
    "ccc-desktop",
    "ccc-server",
    "ccc-claude",
    "ccc-codex",
    "ccc-pi",
    "ccc-opencode",
    "ccc-cline",
    "ccc-hermes",
    "ccc-dsh",
    "ccc-grok",
    "ccc-muse",
    "ccc-aider",
    "ccc-agy",
    "ccc-doctor",
    "ccc-update",
    "ccc-init",
    "community-claude-code"
)

function Show-Usage {
    @"
Usage: install.ps1 [options]

Installs or updates Community Claude Code with Claude Code, Claude Desktop, and OpenCode.
The installer is non-interactive and starts the CCC proxy in the background.

Options:
  -VoiceLocal            Install local Whisper voice transcription support.
  -TorchBackend VALUE    Use a uv PyTorch backend, such as cu130. Requires local voice.
  -RtkHeadroom           Install and configure RTK + Headroom token optimization.
  -DryRun                Print commands without running them.
  -Help                  Show this help text.
"@
}

function Write-Step {
    param([string] $Message)

    Write-Host ""
    Write-Host "==> $Message"
}

function Write-InstallLog {
    param([string] $Message)

    if (-not $script:InstallLog) { return }
    try {
        [IO.File]::AppendAllText($script:InstallLog, "$(Get-Date -Format o) $Message`n", [Text.UTF8Encoding]::new($false))
    }
    catch {
        $script:InstallLog = ""
        if (-not $script:InstallLogWarning) {
            $script:InstallLogWarning = $true
            Write-Warning "Could not write the installer log. Installation will continue. $($_.Exception.Message)"
        }
    }
}

function Initialize-InstallLog {
    if ($DryRun) { return }
    try {
        $directory = Join-Path $env:USERPROFILE ".ccc\logs"
        [void] [IO.Directory]::CreateDirectory($directory)
        $script:InstallLog = Join-Path $directory ("install-$(Get-Date -Format yyyyMMdd-HHmmss)-$([guid]::NewGuid().ToString('N')).log")
        Write-InstallLog "Starting Community Claude Code installer"
    }
    catch {
        $script:InstallLogWarning = $true
        Write-Warning "Could not create the installer log. Installation will continue. $($_.Exception.Message)"
    }
}

function Complete-InstallStep {
    param([string] $Outcome = $script:InstallStepOutcome)

    if (-not $script:CurrentInstallStep) { return }
    $script:InstallSteps[$script:CurrentInstallStep] = $Outcome
    Write-InstallLog "$Outcome`: $script:CurrentInstallStep"
    $script:CurrentInstallStep = ""
}

function Start-InstallStep {
    param([string] $Name, [string] $Message = $Name)

    if ($DryRun) { Write-Step $Message; return }
    if ($script:InstallSteps.Count -eq 0) { return }
    Complete-InstallStep
    $script:CurrentInstallStep = $Name
    $script:InstallStepOutcome = "Completed"
    $script:InstallSteps[$Name] = "Running"
    Write-InstallLog "Starting: $Name"
    if ($script:InstallStageCount -gt 0) {
        $script:InstallStageNumber++
        Write-Host "`n[$($script:InstallStageNumber)/$($script:InstallStageCount)] $Message"
    }
}

function Get-InstallerRetryCommand {
    $options = @()
    $prefix = ""
    $installerRef = "main"
    if ($CccInstallVersion) {
        $prefix = "`$env:CCC_INSTALL_VERSION = '$CccInstallVersion'; "
        $installerRef = "v$CccInstallVersion"
    }
    if ($VoiceLocal) { $options += "-VoiceLocal" }
    if ($TorchBackend) { $options += @("-TorchBackend", $TorchBackend) }
    if ($script:EnableRtkHeadroom) { $options += "-RtkHeadroom" }
    if ($script:InstallerPath -and (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
        return $prefix + "& " + (Format-Command $script:InstallerPath $options)
    }
    return $prefix + "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/theRizwan/community-claude-code/$installerRef/scripts/install.ps1'))) " + (($options | ForEach-Object { Format-Argument $_ }) -join " ")
}

function Show-InstallReport {
    param([bool] $Succeeded, [bool] $Cancelled = $false)

    if ($DryRun) { return }
    if (-not $Succeeded) {
        if ($Cancelled) { Write-Host "`nInstallation cancelled." }
        else { Write-Host "`nInstallation did not finish." }
        foreach ($outcome in @("Completed", "Reused", "Skipped", "Failed", "Cancelled", "Not attempted")) {
            $labels = @($script:InstallSteps.GetEnumerator() | Where-Object { $_.Value -eq $outcome } | ForEach-Object { $_.Key })
            if ($labels.Count -gt 0) { Write-Host "${outcome}: $($labels -join ', ')" }
        }
        Write-Host "Completed changes have been kept. Rerun the installer to try again."
        Write-Host "Retry: $(Get-InstallerRetryCommand)"
        if (-not $Cancelled) { Write-Host "For help, include the terminal error and the installer log." }
    }
    if ($script:InstallLog) { Write-Host "Installer log: $script:InstallLog" }
}

function Write-WindowsLaunchGuidance {
    param([string] $FilePath, [Exception] $Exception, [string] $Stderr = "")

    $policyFailure = $Stderr -match '\(os error (4551|1260)\)'
    for ($cause = $Exception; $null -ne $cause; $cause = $cause.InnerException) {
        if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -in @(4551, 1260)) {
            $policyFailure = $true
        }
        # Start-Process on Windows PowerShell drops the native error code.
        foreach ($code in @(4551, 1260)) {
            if ($cause.Message.Contains([ComponentModel.Win32Exception]::new($code).Message)) {
                $policyFailure = $true
            }
        }
    }
    if ($policyFailure) {
        $guidance = @"
Windows application policy prevented this command from running: '$FilePath'.
Inspect recent policy events to identify the blocked file, then ask your administrator to allow the required application:
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational'; Id=3077,3089; StartTime=(Get-Date).AddMinutes(-15)} | Format-List TimeCreated,Id,Message
"@
        Write-Host $guidance
        Write-InstallLog $guidance
    }
}

function Find-InstalledCodingAgent {
    param([string] $CommandName)

    $originalPath = $env:Path
    try {
        if ($CommandName -eq "opencode" -and $script:OriginalOpenCode) {
            return $script:OriginalOpenCode
        }
        if ($CommandName -in @("pi", "cline", "dsh")) {
            try {
                Add-NpmBinDirectories
            }
            catch {
                # An optional lookup must not prevent choosing other harnesses.
            }
        }
        $command = Get-ApplicationCommand $CommandName
        if (-not $command) {
            if ($CommandName -eq "aider") {
                if ($env:UV_TOOL_BIN_DIR) {
                    Add-PathEntry $env:UV_TOOL_BIN_DIR
                }
                elseif ($env:XDG_BIN_HOME) {
                    Add-PathEntry $env:XDG_BIN_HOME
                }
                elseif ($env:XDG_DATA_HOME) {
                    Add-PathEntry (Join-Path $env:XDG_DATA_HOME "..\bin")
                }
                elseif ($env:USERPROFILE) {
                    Add-PathEntry (Join-Path $env:USERPROFILE ".local\bin")
                }
                $command = Get-ApplicationCommand $CommandName
            }
            elseif ($CommandName -eq "muse") {
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if (-not [string]::IsNullOrWhiteSpace($userPath)) {
                    $env:Path = "$originalPath$([IO.Path]::PathSeparator)$userPath"
                    $command = Get-ApplicationCommand $CommandName
                }
            }
        }
        if ($CommandName -eq "pi" -and $command -and (-not $DryRun)) {
            if (-not (Test-PiApplication $command)) {
                return $null
            }
        }
        return $command
    }
    finally {
        # Environment variables are process-wide, even inside a function.
        $env:Path = $originalPath
    }
}

function Format-Argument {
    param([string] $Value)

    if ($Value -match '^[A-Za-z0-9_./:@%+=,\[\]\\-]+$') {
        return $Value
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-Command {
    param(
        [string] $FilePath,
        [string[]] $Arguments = @()
    )

    $parts = @($FilePath) + $Arguments
    return ($parts | ForEach-Object { Format-Argument ([string] $_) }) -join " "
}

function Invoke-NativeCommand {
    param(
        [string] $FilePath,
        [string[]] $Arguments = @()
    )

    $commandText = Format-Command -FilePath $FilePath -Arguments $Arguments
    Write-Host "+ $commandText"
    if ($DryRun) {
        return
    }

    Write-InstallLog "+ $commandText"
    try {
        $global:LASTEXITCODE = 0
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        Write-InstallLog "Exit code ${exitCode}: $commandText"
        if ($exitCode -ne 0) {
            throw "Command failed with exit code ${exitCode}: $commandText"
        }
    }
    catch {
        Write-InstallLog $_.Exception.Message
        Write-WindowsLaunchGuidance -FilePath $FilePath -Exception $_.Exception
        throw
    }
}

function Invoke-Utf8NativeCapture {
    param(
        [string] $FilePath,
        [string[]] $Arguments = @()
    )

    $commandText = Format-Command -FilePath $FilePath -Arguments $Arguments
    Write-Host "+ $commandText"
    if ($DryRun) { return "" }
    Write-InstallLog "+ $commandText"
    $originalOutputEncoding = [Console]::OutputEncoding
    $originalErrorPreference = $ErrorActionPreference
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = $null
        $captured = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-InstallLog $_.Exception.Message
        Write-WindowsLaunchGuidance -FilePath $FilePath -Exception $_.Exception
        throw
    }
    finally {
        [Console]::OutputEncoding = $originalOutputEncoding
        $ErrorActionPreference = $originalErrorPreference
    }
    $output = ($captured | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | Out-String).Trim()
    $errors = @($captured | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
    $stderr = ($errors | ForEach-Object { $_.ToString() } | Out-String).Trim()
    Write-InstallLog "Exit code ${exitCode}: $commandText`n$output`n$stderr"
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        $cause = if ($errors.Count) { $errors[0].Exception } else { $null }
        Write-WindowsLaunchGuidance -FilePath $FilePath -Exception $cause -Stderr $stderr
        throw "Command failed with exit code ${exitCode}: $commandText`n$output`n$stderr"
    }

    return $output
}

function Get-ApplicationCommand {
    param([string] $Name)

    $commands = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        return $null
    }

    return $commands[0]
}

function Get-PowerShellExecutable {
    param([string] $PowerShellHome = $PSHOME)

    $executableName = if ($PSVersionTable.PSEdition -eq "Core") {
        "pwsh.exe"
    }
    else {
        "powershell.exe"
    }
    $bundledExecutable = Join-Path $PowerShellHome $executableName
    if (Test-Path -LiteralPath $bundledExecutable -PathType Leaf) {
        return $bundledExecutable
    }

    $pathCommand = Get-ApplicationCommand ([IO.Path]::GetFileNameWithoutExtension($executableName))
    if ($pathCommand) {
        return $pathCommand.Source
    }

    throw "Unable to locate a PowerShell executable for the downloaded installer."
}

function Add-PathEntry {
    param([string] $PathEntry)

    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $separator = [IO.Path]::PathSeparator
    $entries = @()
    if (-not [string]::IsNullOrEmpty($env:Path)) {
        $entries = $env:Path -split [regex]::Escape([string] $separator)
    }

    if ($entries -notcontains $PathEntry) {
        $env:Path = "$PathEntry$separator$env:Path"
    }
}

function Prioritize-PathEntry {
    param([string] $PathEntry)

    if ([string]::IsNullOrWhiteSpace($PathEntry)) {
        return
    }

    $separator = [IO.Path]::PathSeparator
    $env:Path = "$PathEntry$separator$env:Path"
}

function Add-KnownBinDirectories {
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-PathEntry (Join-Path $env:USERPROFILE ".local\bin")
        Add-PathEntry (Join-Path $env:USERPROFILE ".opencode\bin")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-PathEntry (Join-Path $env:LOCALAPPDATA "hermes\hermes-agent\bin")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Add-PathEntry (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin")
        Add-PathEntry (Join-Path $env:LOCALAPPDATA "pi-node\current")
        Add-PathEntry (Join-Path $env:LOCALAPPDATA "Programs\Muse Code\bin")
        Add-PathEntry (Join-Path $env:LOCALAPPDATA "agy\bin")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Add-PathEntry (Join-Path $env:APPDATA "npm")
    }
    if ($env:GROK_BIN_DIR) {
        Add-PathEntry $env:GROK_BIN_DIR
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Add-PathEntry (Join-Path $env:USERPROFILE ".grok\bin")
    }
}

function Add-NpmBinDirectories {
    if ($DryRun) {
        return
    }

    Add-KnownBinDirectories
    $npm = Get-ApplicationCommand "npm"
    if (-not $npm) {
        return
    }

    $prefix = (& $npm.Source prefix -g 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prefix)) {
        $prefix = (& $npm.Source config get prefix 2>$null | Out-String).Trim()
    }
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefix)) {
        Add-PathEntry $prefix
    }
}

function Assert-NoCccProcessesRunning {
    $running = @()
    foreach ($commandName in $CccCommands) {
        $processes = @(Get-Process -Name $commandName -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $running += "$commandName (PID $($process.Id))"
        }
    }

    if ($running.Count -gt 0) {
        throw "Community Claude Code is still running ($($running -join ', ')). Stop those processes, then rerun the installer."
    }
}

function Invoke-DownloadedPowerShellInstaller {
    param(
        [string] $Url,
        [string] $Name,
        [switch] $NonInteractive,
        [string[]] $ScriptArguments = @()
    )

    if ($DryRun) {
        Write-Host "+ irm $Url -OutFile <temporary-script>"
        $prefix = if ($NonInteractive) { "CODEX_NON_INTERACTIVE=1 " } else { "" }
        $suffix = if ($ScriptArguments.Count -gt 0) {
            " " + (($ScriptArguments | ForEach-Object { Format-Argument $_ }) -join " ")
        }
        else {
            ""
        }
        Write-Host "+ ${prefix}powershell -NoProfile -ExecutionPolicy Bypass -File <temporary-script>$suffix"
        return
    }

    $temporaryScript = Join-Path ([IO.Path]::GetTempPath()) ("ccc-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        Write-Host "+ irm $Url -OutFile $(Format-Argument $temporaryScript)"
        Invoke-RestMethod -Uri $Url -OutFile $temporaryScript -ErrorAction Stop
        if ((-not (Test-Path -LiteralPath $temporaryScript)) -or ((Get-Item -LiteralPath $temporaryScript).Length -eq 0)) {
            throw "The downloaded $Name installer was empty."
        }

        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $temporaryScript,
            [ref] $tokens,
            [ref] $parseErrors
        ) | Out-Null
        if ($parseErrors.Count -gt 0) {
            throw "The downloaded $Name installer from '$Url' is not valid PowerShell. A network proxy or filter may have replaced it with an HTML response."
        }

        $powerShellPath = Get-PowerShellExecutable

        $hadNonInteractive = Test-Path Env:CODEX_NON_INTERACTIVE
        $previousNonInteractive = $env:CODEX_NON_INTERACTIVE
        try {
            if ($NonInteractive) {
                $env:CODEX_NON_INTERACTIVE = "1"
            }
            $installerArguments = @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                $temporaryScript
            ) + $ScriptArguments
            Invoke-NativeCommand -FilePath $powerShellPath -Arguments $installerArguments
        }
        finally {
            if ($hadNonInteractive) {
                $env:CODEX_NON_INTERACTIVE = $previousNonInteractive
            }
            else {
                Remove-Item Env:CODEX_NON_INTERACTIVE -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-Application {
    param(
        [string] $CommandName,
        [string] $DisplayName
    )

    if ($DryRun) {
        Write-Host "+ $CommandName --version"
        return
    }

    $command = Get-ApplicationCommand $CommandName
    if (-not $command) {
        throw "$DisplayName was installed, but '$CommandName' is not available on PATH."
    }
    Write-Host (Invoke-Utf8NativeCapture -FilePath $command.Source -Arguments @("--version"))
}

function Test-PiApplication {
    param($Command)

    try {
        $helpOutput = (& $Command.Source --help 2>$null | Out-String)
    }
    catch {
        return $false
    }
    return (
        $LASTEXITCODE -eq 0 -and
        $helpOutput.Contains("--extension") -and
        $helpOutput.Contains("--models")
    )
}

function Confirm-PiApplication {
    if ($DryRun) {
        Write-Host "+ pi --help (verify --extension and --models support)"
        Write-Host "+ pi --version"
        return
    }

    $command = Get-ApplicationCommand "pi"
    if (-not $command) {
        throw "Pi was installed, but 'pi' is not available on PATH."
    }
    if (-not (Test-PiApplication $command)) {
        throw "The 'pi' command at '$($command.Source)' is not a compatible Pi Coding Agent."
    }
    Write-Host (Invoke-Utf8NativeCapture -FilePath $command.Source -Arguments @("--version"))
}

function Install-Rtk {
    $archiveUrl = "$RtkReleaseBaseUrl/$RtkWindowsAssetName"
    if ($DryRun) {
        Write-Host "+ irm $archiveUrl -OutFile <temporary-archive>"
        Write-Host "+ verify pinned SHA-256 for $RtkWindowsAssetName"
        Write-Host "+ extract and install rtk.exe to ~/.local/bin"
        return
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccc-rtk-" + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $temporaryRoot $RtkWindowsAssetName
    $extractPath = Join-Path $temporaryRoot "extracted"
    try {
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

        Write-Host "+ irm $archiveUrl -OutFile $(Format-Argument $archivePath)"
        Invoke-RestMethod -Uri $archiveUrl -OutFile $archivePath -ErrorAction Stop
        if ((-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) -or ((Get-Item -LiteralPath $archivePath).Length -eq 0)) {
            throw "The RTK release archive was empty."
        }

        $sha256 = [Security.Cryptography.SHA256]::Create()
        $archiveStream = [IO.File]::OpenRead($archivePath)
        try {
            $actualHash = [BitConverter]::ToString($sha256.ComputeHash($archiveStream)).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $archiveStream.Dispose()
            $sha256.Dispose()
        }
        if ($actualHash -ne $RtkWindowsAssetSha256) {
            throw "RTK checksum verification failed for $RtkWindowsAssetName."
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
        $extractedExecutable = Join-Path $extractPath "rtk.exe"
        if (-not (Test-Path -LiteralPath $extractedExecutable -PathType Leaf)) {
            throw "The verified RTK archive did not contain rtk.exe."
        }

        $installDirectory = Join-Path $env:USERPROFILE ".local\bin"
        New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
        Copy-Item -LiteralPath $extractedExecutable -Destination (Join-Path $installDirectory "rtk.exe") -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RtkCommand {
    param([string[]] $Arguments)

    if ($DryRun) {
        Write-Host "+ RTK_TELEMETRY_DISABLED=1 $(Format-Command -FilePath 'rtk' -Arguments $Arguments)"
        return
    }

    $command = Get-ApplicationCommand "rtk"
    if (-not $command) {
        throw "RTK was installed, but 'rtk' is not available on PATH."
    }

    $hadTelemetryDisabled = Test-Path Env:RTK_TELEMETRY_DISABLED
    $previousTelemetryDisabled = $env:RTK_TELEMETRY_DISABLED
    try {
        $env:RTK_TELEMETRY_DISABLED = "1"
        if ($Arguments[0] -in @("--version", "gain")) {
            Write-Host (Invoke-Utf8NativeCapture -FilePath $command.Source -Arguments $Arguments)
        }
        else {
            Invoke-NativeCommand -FilePath $command.Source -Arguments $Arguments
        }
    }
    finally {
        if ($hadTelemetryDisabled) {
            $env:RTK_TELEMETRY_DISABLED = $previousTelemetryDisabled
        }
        else {
            Remove-Item Env:RTK_TELEMETRY_DISABLED -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-RtkClaudeConfigDirectory {
    $claudeConfigDirectory = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($claudeConfigDirectory)) {
        $claudeConfigDirectory = Join-Path $env:USERPROFILE ".claude"
    }

    if ($DryRun) {
        Write-Host "+ mkdir $(Format-Argument $claudeConfigDirectory)"
        return
    }

    New-Item -ItemType Directory -Force -Path $claudeConfigDirectory | Out-Null
}

function Confirm-RtkApplication {
    if ($DryRun) {
        Invoke-RtkCommand -Arguments @("--version")
        Invoke-RtkCommand -Arguments @("gain")
        return
    }

    $command = Get-ApplicationCommand "rtk"
    if (-not $command) {
        throw "RTK was installed, but 'rtk' is not available on PATH."
    }

    try {
        Invoke-RtkCommand -Arguments @("--version")
        Invoke-RtkCommand -Arguments @("gain")
    }
    catch {
        throw "The 'rtk' command at '$($command.Source)' is not a compatible Rust Token Killer installation. Remove the conflicting command from PATH, then rerun the installer. $($_.Exception.Message)"
    }
}

function Ensure-Rtk {
    if (Get-ApplicationCommand "rtk") {
        Write-Host "RTK already found on PATH; verifying it without updating it."
    }
    else {
        Install-Rtk
        Add-KnownBinDirectories
    }

    Confirm-RtkApplication
}

function Configure-RtkForSelectedAgents {
    if (-not $script:EnableRtkHeadroom) {
        return
    }

    Write-Step "Installing and configuring RTK token optimization"
    Ensure-Rtk

    if ($script:InstallClaudeCode) {
        Ensure-RtkClaudeConfigDirectory
        Invoke-RtkCommand -Arguments @("init", "--global", "--auto-patch")
    }
    if ($script:InstallCodex) {
        Invoke-RtkCommand -Arguments @("init", "--global", "--codex")
    }
    if ($script:InstallPi -and $script:PiAvailable) {
        Invoke-RtkCommand -Arguments @("init", "--global", "--agent", "pi")
    }
    if ($script:InstallCline) {
        Write-Host "Optional for each project: cd <project>; `$env:RTK_TELEMETRY_DISABLED='1'; rtk init --agent cline"
    }
}

function Ensure-Headroom {
    $command = Get-ApplicationCommand "headroom"
    if ($command) {
        $script:HeadroomPath = $command.Source
        Write-Host "Headroom already found on PATH; verifying it without updating it."
    }
    else {
        Invoke-NativeCommand -FilePath "uv" -Arguments @("tool", "install", "--python", $PythonRequest, $HeadroomPackage)
        if ($DryRun) {
            $script:HeadroomPath = "<uv-tool-bin>\headroom.exe"
        }
        else {
            $uvCommand = Get-ApplicationCommand "uv"
            $toolBin = Add-UvToolBinDirectory -UvPath $uvCommand.Source
            $command = Get-ApplicationCommand "headroom"
            if (-not $command -or (Split-Path -Parent $command.Source) -ne $toolBin) {
                throw "Headroom installation did not create its command in the uv tool bin directory."
            }
            $script:HeadroomPath = $command.Source
        }
    }
    Invoke-NativeCommand -FilePath $script:HeadroomPath -Arguments @("--version")
    Invoke-NativeCommand -FilePath $script:HeadroomPath -Arguments @("mcp", "install", "--help")
}

function Configure-HeadroomForSelectedAgents {
    # Headroom 0.40.0's OpenCode registrar uses the pre-v2 schema.
    Write-Host "Headroom setup supports Claude Code, Codex, and Grok. Other selected agents are skipped."
    $agents = @()
    if ($script:InstallClaudeCode) { $agents += "claude" }
    if ($script:InstallCodex) { $agents += "codex" }
    if ($script:InstallGrok) { $agents += "grok" }
    if ($agents.Count -eq 0) {
        Write-Host "Headroom registration skipped: no supported agents selected."
        return
    }
    $previousPath = $env:PATH
    try {
        # Upstream resolves the server executable from PATH.
        $env:PATH = (Split-Path -Parent $script:HeadroomPath) + [IO.Path]::PathSeparator + $env:PATH
        foreach ($agent in $agents) {
            Invoke-NativeCommand -FilePath $script:HeadroomPath -Arguments @("mcp", "install", "--agent", $agent)
        }
    }
    finally {
        $env:PATH = $previousPath
    }
}

function Ensure-ClaudeCode {
    if (Get-ApplicationCommand "claude") {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Claude Code already found on PATH; verifying it."
    }
    else {
        Invoke-DownloadedPowerShellInstaller -Url $ClaudeInstallUrl -Name "Claude Code"
        Add-KnownBinDirectories
    }

    Confirm-Application -CommandName "claude" -DisplayName "Claude Code"
}

function Ensure-ClaudeDesktop {
    if (Get-ApplicationCommand "claude-desktop") {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Claude Desktop already found on PATH; verifying it."
        return
    }
    if ($DryRun) {
        Write-Host "+ winget install --id Anthropic.Claude --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
        Write-Host "+ claude-desktop (verify)"
        return
    }
    $winget = Get-ApplicationCommand "winget"
    if (-not $winget) {
        throw "Claude Desktop installation requires winget. Install the App Installer from Microsoft Store, then rerun the installer."
    }
    Invoke-NativeCommand -FilePath $winget.Source -Arguments @(
        "install",
        "--id",
        "Anthropic.Claude",
        "--exact",
        "--source",
        "winget",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    Add-KnownBinDirectories
    if (-not (Get-ApplicationCommand "claude-desktop")) {
        $packageRoot = Join-Path $env:LOCALAPPDATA "Packages"
        if (-not (Get-ChildItem -LiteralPath $packageRoot -Filter "Claude_*" -ErrorAction SilentlyContinue)) {
            throw "Claude Desktop was installed, but its 'claude-desktop' command is not available."
        }
    }
}

function Ensure-Codex {
    if (Get-ApplicationCommand "codex") {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Codex already found on PATH; verifying it."
    }
    else {
        Invoke-DownloadedPowerShellInstaller -Url $CodexInstallUrl -Name "Codex" -NonInteractive
        Add-KnownBinDirectories
    }

    Confirm-Application -CommandName "codex" -DisplayName "Codex"
}

function Ensure-Pi {
    $script:PiAvailable = $false
    Add-NpmBinDirectories
    $existingPi = Get-ApplicationCommand "pi"
    if ($existingPi -and ($DryRun -or (Test-PiApplication $existingPi))) {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Pi already found on PATH; verifying it."
    }
    else {
        if ($existingPi) {
            Write-Host "The existing 'pi' command at '$($existingPi.Source)' is not Pi Coding Agent; installing Pi."
        }
        Invoke-DownloadedPowerShellInstaller -Url $PiInstallUrl -Name "Pi"
        Add-NpmBinDirectories

        if (-not $DryRun) {
            $currentPi = Get-ApplicationCommand "pi"
            $unchangedIncompatiblePi = (
                $currentPi -and
                $existingPi -and
                $currentPi.Source -eq $existingPi.Source -and
                -not (Test-PiApplication $currentPi)
            )
            if ((-not $currentPi) -or $unchangedIncompatiblePi) {
                $script:InstallStepOutcome = "Skipped"
                Write-Host "Pi was not installed; continuing without it."
                return
            }
        }
    }

    Confirm-PiApplication
    $script:PiAvailable = $true
}

function Convert-SemanticVersionOutput {
    param([string] $Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return ""
    }
    if ($Output -match '(?m)^\s*(?:(?:uv|opencode|cline|dsh|node)(?:\s+version)?\s+|Hermes Agent\s+v?|v)?(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z][0-9A-Za-z.-]*)?)(?:\s+\([^\r\n]*\))?\s*$') {
        return $Matches["version"]
    }
    return ""
}

function Test-SupportedStableVersion {
    param(
        [string] $Version,
        [string] $Minimum
    )

    $parsedVersion = Convert-SemanticVersionOutput $Version
    $parsedMinimum = Convert-SemanticVersionOutput $Minimum
    if ([string]::IsNullOrWhiteSpace($parsedVersion) -or [string]::IsNullOrWhiteSpace($parsedMinimum)) {
        throw "Unable to compare semantic versions."
    }
    if ($parsedVersion.Contains("-")) {
        return $false
    }

    $normalizedVersion = $parsedVersion -replace '\+.*$', ''
    $normalizedMinimum = $parsedMinimum -replace '\+.*$', ''
    return ([version] $normalizedVersion) -ge ([version] $normalizedMinimum)
}

function Read-OpenCodeVersionOutput {
    param([string] $OpenCodePath)

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccc-opencode-version-" + [guid]::NewGuid().ToString("N"))
    $stdoutPath = Join-Path $temporaryRoot "stdout.txt"
    $stderrPath = Join-Path $temporaryRoot "stderr.txt"
    $process = $null
    try {
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $process = Start-Process -FilePath $OpenCodePath -ArgumentList @("--version") -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        # Windows PowerShell needs the handle retained to report the exit code.
        [void] $process.Handle
        if (-not $process.WaitForExit(10000)) {
            & "$env:SYSTEMROOT\System32\taskkill.exe" /PID $process.Id /T /F *> $null
            [void] $process.WaitForExit(5000)
            throw "OpenCode version probe timed out at '$OpenCodePath'."
        }
        if ($process.ExitCode -ne 0) {
            throw "OpenCode version probe failed at '$OpenCodePath' (exit code $($process.ExitCode))."
        }
        return [IO.File]::ReadAllText($stdoutPath)
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenCodeVersion {
    param([string] $OpenCodePath)

    $output = Read-OpenCodeVersionOutput $OpenCodePath
    if ($output -match '(?m)^\s*(?:opencode(?:\s+version)?\s+)?v?(?<version>\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?)\s*$') {
        return $Matches["version"]
    }
    return ""
}

function Get-OpenCodeRtkPlugin {
    $pluginPath = Join-Path $env:USERPROFILE ".config\opencode\plugins\rtk.ts"
    try {
        $plugin = Get-Item -LiteralPath $pluginPath -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
    if ($plugin.PSIsContainer -or ($plugin.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Disable or migrate the RTK plugin at '$pluginPath' manually, then rerun the installer."
    }
    # These include the backup's parent; a junction must not redirect either move.
    foreach ($relativePath in @(".config", ".config\opencode", ".config\opencode\plugins")) {
        $parent = Get-Item -LiteralPath (Join-Path $env:USERPROFILE $relativePath) -Force -ErrorAction Stop
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The RTK plugin directory is linked: '$($parent.FullName)'. Disable or migrate it manually, then rerun the installer."
        }
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha256.ComputeHash([IO.File]::ReadAllBytes($pluginPath))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
    if ($hash -ne "6530c131946c84892f9522abd68d4e513e1e658d8ddbad1f59388c86ebbcb6bb") {
        throw "The RTK plugin at '$pluginPath' was modified or is unrecognized. Disable or migrate it manually, then rerun the installer."
    }
    return $pluginPath
}

function Get-OpenCodeWindowsAssetName {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }

    switch ($architecture.ToUpperInvariant()) {
        "ARM64" { return "opencode-windows-arm64.zip" }
        "AMD64" { return "opencode-windows-x64-baseline.zip" }
        "X64" { return "opencode-windows-x64-baseline.zip" }
        "X86_64" { return "opencode-windows-x64-baseline.zip" }
        default { throw "OpenCode does not provide a supported Windows release for architecture '$architecture'." }
    }
}

function Assert-NoOpenCodeProcessesRunning {
    $running = @(Get-Process -Name opencode,opencode2 -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:4096/global/health" -TimeoutSec 2 -ErrorAction Stop
        if ($health.healthy -and $health.version -match '^1\.19\.') {
            Write-Host "OpenCode 1.19.x server is running; leaving it in place."
            return
        }
    }
    catch {
        # Not our reusable v1 server; replacing it requires stopping it.
    }
    throw "Close OpenCode before replacing its executable or RTK plugin, then rerun the installer."
}

function Install-OpenCode {
    $assetName = Get-OpenCodeWindowsAssetName
    $installDirectory = Join-Path $env:USERPROFILE ".opencode\bin"
    if ($DryRun) {
        Write-Host "+ resolve latest stable OpenCode 2 and download $assetName"
        Write-Host "+ extract and install opencode.exe to $(Format-Argument $installDirectory)"
        return
    }

    $release = Invoke-RestMethod -Uri "https://opencode.ai/update/api/latest/cli/npm" -ErrorAction Stop
    if ($release.version -isnot [string] -or $release.version -notmatch '^2\.\d+\.\d+$') {
        throw "The OpenCode release channel did not return a stable OpenCode 2 version."
    }
    $archiveUrl = "$OpenCodeReleaseBaseUrl/$($release.version)/$assetName"

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccc-opencode-" + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $temporaryRoot $assetName
    $extractPath = Join-Path $temporaryRoot "extracted"
    $temporaryInstallPath = Join-Path $installDirectory (".opencode-" + [guid]::NewGuid().ToString("N") + ".exe")
    try {
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        Write-Host "+ irm $archiveUrl -OutFile $(Format-Argument $archivePath)"
        Invoke-RestMethod -Uri $archiveUrl -OutFile $archivePath -ErrorAction Stop
        if ((-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) -or ((Get-Item -LiteralPath $archivePath).Length -eq 0)) {
            throw "The OpenCode release archive was empty."
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
        $executables = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "opencode.exe")
        if ($executables.Count -ne 1) {
            throw "The OpenCode release archive did not contain exactly one opencode.exe."
        }
        $version = Get-OpenCodeVersion $executables[0].FullName
        if (($version -replace '\+.*$', '') -ne $release.version) {
            throw "The OpenCode archive did not contain the selected stable version $($release.version)."
        }

        New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
        Copy-Item -LiteralPath $executables[0].FullName -Destination $temporaryInstallPath
        if ((-not (Test-Path -LiteralPath $temporaryInstallPath -PathType Leaf)) -or ((Get-Item -LiteralPath $temporaryInstallPath).Length -eq 0)) {
            throw "The extracted OpenCode executable was empty."
        }
        Assert-NoOpenCodeProcessesRunning
        Move-Item -LiteralPath $temporaryInstallPath -Destination (Join-Path $installDirectory "opencode.exe") -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryInstallPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-LatestOpenCodeV1 {
    $metadataPath = [IO.Path]::GetTempFileName()
    try {
        Invoke-RestMethod -Uri "https://registry.npmjs.org/-/package/opencode-ai/dist-tags" -OutFile $metadataPath -TimeoutSec 10 -ErrorAction Stop
        $text = [IO.File]::ReadAllText($metadataPath)
        if ([regex]::Matches($text, '"latest"\s*:').Count -ne 1) {
            throw "The registry must contain exactly one latest tag."
        }
        $version = ($text | ConvertFrom-Json -ErrorAction Stop).latest
        if ($version -isnot [string] -or $version -notmatch '^1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or [version] $version -lt [version] "1.19.0") {
            throw "The latest tag must be a stable v1 release at or above 1.19.0."
        }
        return $version
    }
    catch {
        throw "Could not discover the latest OpenCode 1 release: $($_.Exception.Message) Upgrade OpenCode manually, then rerun the installer."
    }
    finally {
        Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenCodeUpgrade {
    param([string] $OpenCodePath, [string] $Target)

    Assert-NoOpenCodeProcessesRunning
    $savedPath = $env:Path
    $savedVersion = $env:VERSION
    try {
        $env:VERSION = $null
        if ($script:OriginalOpenCode -and $script:OriginalOpenCodeSearchPath) {
            # Installer-added directories must not hide a failed upgrade behind another copy.
            $env:Path = $script:OriginalOpenCodeSearchPath
        }
        Invoke-NativeCommand -FilePath $OpenCodePath -Arguments @("upgrade", $Target) | Out-Host
        $command = Get-ApplicationCommand "opencode"
        if (-not $command) { throw "OpenCode is missing from PATH." }
        $version = Get-OpenCodeVersion $command.Source
        if ($Target -eq "--major" -and $version -notmatch '^2\.') {
            throw "Found '$version' at '$($command.Source)' instead of stable OpenCode 2."
        }
        return [pscustomobject] @{ Command = $command; Version = $version }
    }
    catch {
        throw "OpenCode upgrade $Target failed: $($_.Exception.Message) Finish the official upgrade manually, then rerun the installer."
    }
    finally {
        $env:Path = $savedPath
        $env:VERSION = $savedVersion
    }
}

function Get-OpenCodeInstallState {
    $command = if ($script:OriginalOpenCode) { $script:OriginalOpenCode } else { Get-ApplicationCommand "opencode" }
    $nativePath = Join-Path $env:USERPROFILE ".opencode\bin\opencode.exe"
    $action = "install"
    $version = ""
    if ($command) {
        $version = Get-OpenCodeVersion $command.Source
        if ($version -match '^2\.') {
            $action = "reuse"
        }
        elseif ($version -match '^1\.') {
            $action = "upgrade"
        }
        else {
            throw "OpenCode at '$($command.Source)' is not a recognized stable v1 or v2. Correct that installation, then rerun the installer. See https://opencode.ai/v2/docs/migrate-v1/"
        }
    }
    $pluginPath = Get-OpenCodeRtkPlugin
    if ($action -ne "reuse" -or $pluginPath) {
        Assert-NoOpenCodeProcessesRunning
    }
    if ($action -eq "install") {
        foreach ($target in @((Join-Path $env:USERPROFILE ".opencode"), (Split-Path -Parent $nativePath), $nativePath)) {
            $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "OpenCode installation path is linked: '$target'. Migrate it manually."
            }
        }
    }
    return [pscustomobject] @{ Action = $action; Command = $command; Version = $version; PluginPath = $pluginPath }
}

function Ensure-NodeRuntime {
    if (Get-ApplicationCommand "npm") { return }

    Write-Host "Node.js is required to install the OpenCode 1 runtime."
    $winget = Get-ApplicationCommand "winget"
    if (-not $winget) {
        throw "OpenCode installation requires npm. Install Node.js from https://nodejs.org/en/download, then rerun the installer."
    }
    Invoke-NativeCommand -FilePath $winget.Source -Arguments @(
        "install",
        "--id",
        "OpenJS.NodeJS.LTS",
        "--exact",
        "--source",
        "winget",
        "--silent",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )
    Add-KnownBinDirectories
}

function Ensure-OpenCode {
    # The free-model shim uses the OpenCode 1 session API, so pin 1.19.x.
    $wanted = "1.19.5"
    $command = Get-ApplicationCommand "opencode"
    if ($command) {
        $version = Get-OpenCodeVersion $command.Source
        if ($version -match '^1\.19\.') {
            $script:InstallStepOutcome = "Reused"
            Write-Host "OpenCode $version already found on PATH; reusing it."
            return
        }
    }
    if ($DryRun) {
        Write-Host "+ npm install -g opencode-ai@$wanted --force"
        Write-Host "+ opencode --version (verify 1.19.x)"
        return
    }

    Assert-NoOpenCodeProcessesRunning
    Ensure-NodeRuntime
    $npm = Get-ApplicationCommand "npm"
    if (-not $npm) {
        throw "OpenCode installation requires npm. Install Node.js from https://nodejs.org/en/download, then rerun the installer."
    }
    Invoke-NativeCommand -FilePath $npm.Source -Arguments @("install", "-g", "opencode-ai@$wanted", "--force")
    Add-NpmBinDirectories

    $command = Get-ApplicationCommand "opencode"
    if (-not $command) { throw "OpenCode is not available on PATH after installation." }
    $version = Get-OpenCodeVersion $command.Source
    if ($version -notmatch '^1\.19\.') {
        throw "OpenCode at '$($command.Source)' is not 1.19.x (found '$version'). Remove the conflicting OpenCode 2 installation, then rerun the installer."
    }
    Write-Host "Verified OpenCode $version at '$($command.Source)'."
}

function Ensure-Cline {
    Add-NpmBinDirectories

    $command = Get-ApplicationCommand "cline"
    if ($command) {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Cline already found on PATH; verifying it."
    }
    else {
        $npm = Get-ApplicationCommand "npm"
        if (-not $npm) {
            throw "Cline installation requires npm. Install Node.js from https://nodejs.org/en/download, then rerun the installer."
        }
        Invoke-NativeCommand -FilePath $npm.Source -Arguments @("install", "-g", "cline")
        Add-NpmBinDirectories
    }

    Confirm-Application -CommandName "cline" -DisplayName "Cline"
}

function Confirm-HermesArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    if ($architecture.ToUpperInvariant() -notin @("ARM64", "AMD64", "X64", "X86_64")) {
        throw "Hermes Agent does not provide a supported Windows release for architecture '$architecture'."
    }
}

function Install-Hermes {
    Confirm-HermesArchitecture
    Invoke-DownloadedPowerShellInstaller `
        -Url $HermesInstallUrl `
        -Name "Hermes Agent" `
        -ScriptArguments @("-NonInteractive")
    Add-KnownBinDirectories
}

function Ensure-Hermes {
    $command = Get-ApplicationCommand "hermes"
    if ($command) {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Hermes Agent already found on PATH; verifying it."
    }
    else {
        Install-Hermes
    }

    Confirm-Application -CommandName "hermes" -DisplayName "Hermes Agent"
}

function Install-Grok {
    Invoke-DownloadedPowerShellInstaller -Url $GrokInstallUrl -Name "Grok Build"
    Add-KnownBinDirectories
}

function Ensure-Grok {
    $command = Get-ApplicationCommand "grok"
    if ($command) {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Grok Build already found on PATH; verifying it."
    }
    else {
        Install-Grok
    }

    Confirm-Application -CommandName "grok" -DisplayName "Grok Build"
}

function Get-AgyVersion {
    param([string] $AgyPath)

    $output = Invoke-Utf8NativeCapture -FilePath $AgyPath -Arguments @("--version")
    if ($output -notmatch '^\s*(?<version>\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?)\s*$') {
        throw "Antigravity CLI is present, but 'agy --version' did not return a stable semantic version."
    }
    return $Matches['version']
}

function Ensure-Agy {
    Add-KnownBinDirectories
    $command = Get-ApplicationCommand "agy"
    if ($DryRun) {
        if ($command) {
            Write-Host "+ agy --version"
            Write-Host "Antigravity CLI >=$AgyMinimumVersion will be preserved; an older version will be upgraded with agy update."
        }
        else {
            Invoke-DownloadedPowerShellInstaller -Url $AgyInstallUrl -Name "Antigravity CLI"
            Write-Host "+ agy --version"
        }
        return
    }
    if ($command) {
        $version = Get-AgyVersion $command.Source
        if (Test-SupportedStableVersion $version $AgyMinimumVersion) {
            $script:InstallStepOutcome = "Reused"
            Write-Host "Antigravity CLI $version already satisfies >=$AgyMinimumVersion; leaving it unchanged."
            return
        }
    }
    if (@(Get-Process -Name agy -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "Close Antigravity CLI before replacing its executable, then rerun the installer."
    }
    if ($command) {
        Invoke-NativeCommand -FilePath $command.Source -Arguments @("update")
    }
    else {
        Invoke-DownloadedPowerShellInstaller -Url $AgyInstallUrl -Name "Antigravity CLI"
        Add-KnownBinDirectories
    }
    $command = Get-ApplicationCommand "agy"
    if (-not $command) {
        throw "Antigravity CLI was installed, but 'agy' is not available on PATH."
    }
    $version = Get-AgyVersion $command.Source
    if (-not (Test-SupportedStableVersion $version $AgyMinimumVersion)) {
        throw "Antigravity CLI requires >=$AgyMinimumVersion; found $version after installation."
    }
    Write-Host "Verified Antigravity CLI $version."
}

function Install-Aider {
    $uvPath = "uv"
    if (-not $DryRun) {
        $uvCommand = Get-ApplicationCommand "uv"
        if (-not $uvCommand) {
            throw "Aider installation requires the verified uv command, but it is not available on PATH."
        }
        $uvPath = $uvCommand.Source
    }

    Invoke-NativeCommand -FilePath $uvPath -Arguments @(
        "tool",
        "install",
        "--force",
        "--python",
        "python3.12",
        "--with",
        "pip",
        "aider-chat@latest"
    )
}

function Add-UvToolBinDirectory {
    param([string] $UvPath)

    $toolBin = Invoke-Utf8NativeCapture -FilePath $UvPath -Arguments @("tool", "dir", "--bin")
    if ([string]::IsNullOrWhiteSpace($toolBin)) {
        throw "uv returned an empty tool bin directory."
    }

    Add-PathEntry $toolBin
    return $toolBin
}

function Ensure-Aider {
    $command = Get-ApplicationCommand "aider"
    if ((-not $command) -and (-not $DryRun)) {
        $uvCommand = Get-ApplicationCommand "uv"
        if (-not $uvCommand) {
            throw "Aider installation requires the verified uv command, but it is not available on PATH."
        }
        $null = Add-UvToolBinDirectory -UvPath $uvCommand.Source
        $command = Get-ApplicationCommand "aider"
    }

    if ($command) {
        $script:InstallStepOutcome = "Reused"
        Write-Host "Aider already found on PATH; verifying it."
    }
    else {
        Install-Aider
    }

    Confirm-Application -CommandName "aider" -DisplayName "Aider"
}

function Ensure-Muse {
    $script:MuseAvailable = $false
    Invoke-DownloadedPowerShellInstaller -Url $MuseInstallUrl -Name "Muse Code"
    Add-KnownBinDirectories
    $commandName = "muse"
    if (-not $DryRun) {
        $command = Find-InstalledCodingAgent "muse"
        if (-not $command) {
            throw "Muse Code was installed, but 'muse' is not available on PATH."
        }
        $commandName = $command.Source
    }
    Confirm-Application -CommandName $commandName -DisplayName "Muse Code"
    $script:MuseAvailable = $true
}

function Get-DshVersion {
    param([string] $DshPath)

    $output = Invoke-Utf8NativeCapture -FilePath $DshPath -Arguments @("--version")
    if ($output -notmatch '(?m)^\s*(?:dsh\s+)?v?(?<version>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)\s*$') {
        throw "DeepSeek Harness is present, but 'dsh --version' did not return a semantic version."
    }
    return $Matches['version']
}

function Test-DshVersion {
    param([string] $Version)

    $versionParts = ($Version -replace '\+.*$', '') -split '-', 2
    $minimumParts = $DshMinimumVersion -split '-', 2
    if ($versionParts[0] -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
        return $false
    }
    $preview = @()
    if ($versionParts.Count -gt 1) {
        $preview = @($versionParts[1] -split '\.')
        foreach ($part in $preview) {
            if ($part -notmatch '^[0-9A-Za-z-]+$' -or $part -match '^0[0-9]+$') { return $false }
        }
    }
    $release = [version] $versionParts[0]
    $minimum = [version] $minimumParts[0]
    if ($release -ne $minimum) { return $release -gt $minimum }
    if ($preview.Count -eq 0) { return $true }
    $floor = @($minimumParts[1] -split '\.')
    for ($index = 0; $index -lt [Math]::Min($preview.Count, $floor.Count); $index++) {
        $part = $preview[$index]
        $base = $floor[$index]
        if ($part -ceq $base) { continue }
        $numeric = $part -match '^[0-9]+$'
        $baseNumeric = $base -match '^[0-9]+$'
        if ($numeric -and $baseNumeric) {
            if ($part.Length -ne $base.Length) { return $part.Length -gt $base.Length }
        }
        elseif ($numeric -ne $baseNumeric) { return $baseNumeric }
        return [string]::CompareOrdinal($part, $base) -gt 0
    }
    return $preview.Count -ge $floor.Count
}

function Get-DshNodeVersion {
    param([string] $NodePath)

    $output = Invoke-Utf8NativeCapture -FilePath $NodePath -Arguments @("--version")
    $version = Convert-SemanticVersionOutput $output
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "DeepSeek Harness requires a readable Node.js version."
    }
    return $version
}

function Test-DshNodeVersion {
    param([string] $Version)

    try {
        $parsed = [version] (($Version -replace '^v', '') -replace '[-+].*$', '')
    }
    catch {
        return $false
    }
    return (
        (($parsed.Major -eq 22) -and ($parsed.Minor -ge 19)) -or
        ($parsed.Major -ge 24)
    )
}

function Test-DshToolchain {
    $node = Get-ApplicationCommand "node"
    $npm = Get-ApplicationCommand "npm"
    if ((-not $node) -or (-not $npm)) {
        return $false
    }
    try {
        return (Test-DshNodeVersion -Version (Get-DshNodeVersion $node.Source))
    }
    catch {
        return $false
    }
}

function Confirm-DshToolchain {
    $node = Get-ApplicationCommand "node"
    if (-not $node) {
        throw "DeepSeek Harness requires Node.js ^22.19.0 or >=24.0.0 and npm. Install Node.js, then rerun the installer."
    }
    $npm = Get-ApplicationCommand "npm"
    if (-not $npm) {
        throw "DeepSeek Harness requires npm. Install npm, then rerun the installer."
    }
    $version = Get-DshNodeVersion $node.Source
    if (-not (Test-DshNodeVersion $version)) {
        throw "DeepSeek Harness requires Node.js ^22.19.0 or >=24.0.0; found Node.js $version."
    }
    return $npm.Source
}

function Confirm-DshApplication {
    if ($DryRun) {
        Write-Host "+ dsh --version"
        return
    }

    $command = Get-ApplicationCommand "dsh"
    if (-not $command) {
        throw "DeepSeek Harness was installed, but 'dsh' is not available on PATH."
    }
    $version = Get-DshVersion $command.Source
    if (-not (Test-DshVersion $version)) {
        throw "DeepSeek Harness requires >=$DshMinimumVersion; found $version after installation."
    }
    Write-Host "Verified DeepSeek Harness $version."
}

function Install-Dsh {
    $npmPath = Confirm-DshToolchain
    Invoke-NativeCommand -FilePath $npmPath -Arguments @("install", "-g", $DshPackage)
    Add-NpmBinDirectories
}

function Ensure-Dsh {
    Add-NpmBinDirectories

    if ($DryRun) {
        if (Get-ApplicationCommand "dsh") {
            Write-Host "+ dsh --version"
            Write-Host "DeepSeek Harness >=$DshMinimumVersion will be preserved; an older version will be upgraded to latest."
        }
        else {
            $node = Get-ApplicationCommand "node"
            $npm = Get-ApplicationCommand "npm"
            if ((-not $node) -or (-not $npm)) {
                throw "DeepSeek Harness requires Node.js ^22.19.0 or >=24.0.0 and npm. Install Node.js, then rerun the installer."
            }
            $npmPath = $npm.Source
            Write-Host "+ $(Format-Command -FilePath $npmPath -Arguments @('install', '-g', $DshPackage))"
        }
        Confirm-DshApplication
        return
    }

    [void] (Confirm-DshToolchain)
    $command = Get-ApplicationCommand "dsh"
    if ($command) {
        $version = Get-DshVersion $command.Source
        if (Test-DshVersion $version) {
            $script:InstallStepOutcome = "Reused"
            Write-Host "DeepSeek Harness $version already satisfies >=$DshMinimumVersion; leaving it unchanged."
            return
        }
        Write-Host "DeepSeek Harness requires >=$DshMinimumVersion; upgrading $version to latest."
    }

    Install-Dsh
    Confirm-DshApplication
}

function Confirm-SelectedPrerequisites {
    if ($DryRun) { return }
    # Pi can bootstrap Node/npm before the dependent agents are installed.
    $installingPi = $script:InstallPi -and -not (Find-InstalledCodingAgent "pi")
    if (-not $installingPi) {
        if ($script:InstallDsh) { [void] (Confirm-DshToolchain) }
        if ($script:InstallCline -and -not (Get-ApplicationCommand "cline") -and -not (Get-ApplicationCommand "npm")) {
            throw "Cline installation requires npm. Install Node.js from https://nodejs.org/en/download, then rerun the installer."
        }
    }
    if ($script:InstallHermes -and -not (Get-ApplicationCommand "hermes")) { Confirm-HermesArchitecture }
    if ($script:InstallOpenCode) {
        $state = Get-OpenCodeInstallState
        if ($state.Action -eq "install") { [void] (Get-OpenCodeWindowsAssetName) }
    }
}

function Ensure-SelectedCodingAgents {
    if ($script:InstallClaudeCode) {
        Start-InstallStep "Claude Code" "Ensuring Claude Code is installed"
        Ensure-ClaudeCode
    }

    if ($script:InstallCodex) {
        Start-InstallStep "Codex" "Ensuring Codex is installed"
        Ensure-Codex
    }

    if ($script:InstallPi) {
        Start-InstallStep "Pi" "Checking or installing Pi"
        Ensure-Pi
    }

    if ($script:InstallOpenCode) {
        Start-InstallStep "OpenCode" "Ensuring OpenCode is installed"
        Ensure-OpenCode
    }

    if ($script:InstallCline) {
        Start-InstallStep "Cline" "Ensuring Cline CLI is installed"
        Ensure-Cline
    }

    if ($script:InstallHermes) {
        Start-InstallStep "Hermes" "Ensuring Hermes Agent is installed"
        Ensure-Hermes
    }

    if ($script:InstallDsh) {
        Start-InstallStep "DeepSeek Harness" "Ensuring DeepSeek Harness is installed"
        Ensure-Dsh
    }

    if ($script:InstallGrok) {
        Start-InstallStep "Grok" "Ensuring Grok Build is installed"
        Ensure-Grok
    }

    if ($script:InstallMuse) {
        Start-InstallStep "Muse" "Ensuring Muse Code is installed"
        Ensure-Muse
    }

    if ($script:InstallAider) {
        Start-InstallStep "Aider" "Ensuring Aider is installed"
        Ensure-Aider
    }

    if ($script:InstallAgy) {
        Start-InstallStep "Antigravity CLI" "Ensuring Antigravity CLI is installed"
        Ensure-Agy
    }

    if ((-not $script:InstallClaudeCode) -and (-not $script:InstallCodex) -and (-not $script:PiAvailable) -and (-not $script:InstallOpenCode) -and (-not $script:InstallCline) -and (-not $script:InstallHermes) -and (-not $script:InstallDsh) -and (-not $script:InstallGrok) -and (-not $script:MuseAvailable) -and (-not $script:InstallAider) -and (-not $script:InstallAgy)) {
        throw "No selected coding agent was installed. Re-run the installer and choose at least one."
    }
}

function Get-UvVersion {
    param([string] $UvPath)

    $output = Invoke-Utf8NativeCapture -FilePath $UvPath -Arguments @("--version")
    $version = Convert-SemanticVersionOutput $output
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "uv is present, but 'uv --version' did not return a valid version."
    }

    return $version
}

function Confirm-Uv {
    if ($DryRun) {
        Write-Host "+ uv --version"
        return
    }

    $uvCommand = Get-ApplicationCommand "uv"
    if (-not $uvCommand) {
        throw "uv was installed, but it is not available on PATH."
    }

    $version = Get-UvVersion $uvCommand.Source
    if (-not (Test-SupportedStableVersion -Version $version -Minimum $MinUvVersion)) {
        throw "Stable uv $MinUvVersion or newer is required; found uv $version after installation."
    }
    Write-Host "Verified uv $version."
}

function Get-UvInstallBinDirectory {
    $forceInstallDirectory = if (-not [string]::IsNullOrWhiteSpace($env:UV_INSTALL_DIR)) {
        $env:UV_INSTALL_DIR
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:UV_UNMANAGED_INSTALL)) {
        $env:UV_UNMANAGED_INSTALL
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($forceInstallDirectory)) {
        $cargoHome = if (-not [string]::IsNullOrWhiteSpace($env:CARGO_HOME)) {
            $env:CARGO_HOME
        }
        elseif (-not [string]::IsNullOrWhiteSpace($HOME)) {
            Join-Path $HOME ".cargo"
        }
        else {
            $null
        }
        if ($cargoHome -and $forceInstallDirectory.Replace("\\", "\") -eq $cargoHome) {
            return Join-Path $forceInstallDirectory "bin"
        }
        return $forceInstallDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XDG_BIN_HOME)) {
        return $env:XDG_BIN_HOME
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
        return Join-Path $env:XDG_DATA_HOME "..\bin"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return Join-Path $env:USERPROFILE ".local\bin"
    }

    throw "Could not determine where the standalone uv installer places uv."
}

function Ensure-Uv {
    if ($DryRun) {
        if (Get-ApplicationCommand "uv") {
            Write-Host "+ uv --version"
            Write-Host "A compatible existing uv will be left unchanged; an obsolete one will be replaced by the standalone installer."
        }
        else {
            Write-Host "uv is not installed; the current standalone uv would be installed."
            Invoke-DownloadedPowerShellInstaller -Url $UvInstallUrl -Name "uv"
            Confirm-Uv
        }
        return
    }

    $uvCommand = Get-ApplicationCommand "uv"
    if ($uvCommand) {
        $version = Get-UvVersion $uvCommand.Source
        if (Test-SupportedStableVersion -Version $version -Minimum $MinUvVersion) {
            $script:InstallStepOutcome = "Reused"
            Write-Host "uv $version already satisfies >=$MinUvVersion; leaving it unchanged."
            return
        }
        Write-Host "uv $version does not satisfy stable >=$MinUvVersion; installing the current standalone uv."
    }
    else {
        Write-Host "uv is not installed; installing the current standalone uv."
    }

    Invoke-DownloadedPowerShellInstaller -Url $UvInstallUrl -Name "uv"
    Prioritize-PathEntry (Get-UvInstallBinDirectory)
    Confirm-Uv
}

function Get-PackageSpec {
    $name = if ($VoiceLocal) { "community-claude-code[voice_local]" } else { "community-claude-code" }
    $ref = if ($CccInstallVersion) { "v$CccInstallVersion" }
    elseif ($DryRun) { "v<selected-release>" }
    else { throw "No Community Claude Code release was selected." }
    return "$name @ git+$CccRepoUrl@$ref"
}

function Install-CommunityClaudeCode {
    Assert-NoCccProcessesRunning
    $packageSpec = Get-PackageSpec
    if (-not $DryRun -and -not (Get-ApplicationCommand "git")) {
        throw "git is required to install Community Claude Code from GitHub."
    }
    $arguments = @(
        "tool",
        "install",
        "--force",
        "--refresh-package",
        "community-claude-code",
        "--python",
        $PythonRequest
    )
    if (-not [string]::IsNullOrWhiteSpace($TorchBackend)) {
        $arguments += @("--torch-backend", $TorchBackend)
    }
    $arguments += $packageSpec

    $uvPath = "uv"
    if (-not $DryRun) {
        $uvCommand = Get-ApplicationCommand "uv"
        if (-not $uvCommand) {
            throw "uv is not available for the Community Claude Code installation."
        }
        $uvPath = $uvCommand.Source
    }
    Invoke-NativeCommand -FilePath $uvPath -Arguments $arguments
}

function Export-CccDesktopIcon {
    param(
        [string] $DesktopCommand,
        [string] $IconPath
    )

    $arguments = @("--export-icon", $IconPath)
    $commandText = Format-Command -FilePath $DesktopCommand -Arguments $arguments
    Write-Host "+ $commandText"
    if ($DryRun) {
        return
    }

    # PowerShell does not wait when directly invoking a Windows GUI executable.
    $process = Start-Process `
        -FilePath $DesktopCommand `
        -ArgumentList @("--export-icon", ('"' + $IconPath + '"')) `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    try {
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $commandText"
    }
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
        throw "Community Claude Code did not export its Windows app icon to '$IconPath'."
    }
}

function Invoke-CccBootstrap {
    param([string[]] $Arguments)

    $commandText = Format-Command -FilePath "ccc-bootstrap" -Arguments $Arguments
    Write-Host "+ $commandText"
    if ($DryRun) { return }
    $command = Get-ApplicationCommand "ccc-bootstrap"
    if (-not $command) {
        throw "Community Claude Code did not install the 'ccc-bootstrap' command."
    }
    Invoke-NativeCommand -FilePath $command.Source -Arguments $Arguments
}

function Install-CccStartupShortcut {
    param([string] $DesktopCommand)

    $shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Community Claude Code.lnk"
    Write-Host "+ create startup shortcut $(Format-Argument $shortcutPath) -> $(Format-Argument $DesktopCommand) --auto-started"
    if ($DryRun) { return }

    $parent = Split-Path -Parent $shortcutPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $DesktopCommand
    $shortcut.Arguments = "--auto-started"
    $shortcut.WorkingDirectory = $env:USERPROFILE
    $shortcut.Description = "Start Community Claude Code and OpenCode in the background"
    if ($script:CccIconPath) {
        $shortcut.IconLocation = "$($script:CccIconPath),0"
    }
    $shortcut.Save()
}

function Configure-AndConfirmCommunityClaudeCode {
    Start-InstallStep "PATH configuration"
    $iconPath = Join-Path $env:USERPROFILE ".ccc\app-icon.ico"
    if ($DryRun) {
        Write-Host "+ uv tool update-shell"
        Write-Host "+ uv tool dir --bin"
        Write-Host "+ verify ccc-desktop, ccc-server, ccc-claude, ccc-codex, ccc-pi, ccc-opencode, ccc-cline, ccc-hermes, ccc-dsh, ccc-grok, ccc-muse, ccc-aider, ccc-agy, and ccc-bootstrap in the uv tool bin directory"
        Write-Host "+ ccc-server --version"
        Export-CccDesktopIcon `
            -DesktopCommand "<uv-tool-bin>\ccc-desktop.exe" `
            -IconPath $iconPath
        Install-CccDesktopShortcuts `
            -DesktopCommand "<uv-tool-bin>\ccc-desktop.exe" `
            -IconPath $iconPath
        $script:CccDesktopCommand = "<uv-tool-bin>\ccc-desktop.exe"
        $script:CccIconPath = $iconPath
        return
    }

    $uvCommand = Get-ApplicationCommand "uv"
    if (-not $uvCommand) {
        throw "uv is not available for PATH configuration."
    }
    Invoke-NativeCommand -FilePath $uvCommand.Source -Arguments @("tool", "update-shell")
    $toolBin = Add-UvToolBinDirectory -UvPath $uvCommand.Source
    Start-InstallStep "CCC verification"
    $toolBinPath = ([IO.Path]::GetFullPath($toolBin)).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $installedCommands = @{}
    foreach ($commandName in @("ccc-desktop", "ccc-server", "ccc-claude", "ccc-codex", "ccc-pi", "ccc-opencode", "ccc-cline", "ccc-hermes", "ccc-dsh", "ccc-grok", "ccc-muse", "ccc-aider", "ccc-agy", "ccc-bootstrap", "ccc-doctor", "ccc-update.cmd")) {
        $command = Get-ApplicationCommand $commandName
        if (-not $command) {
            throw "Community Claude Code installation did not create '$commandName'."
        }
        $commandDirectory = ([IO.Path]::GetFullPath((Split-Path -Parent $command.Source))).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        if (-not $commandDirectory.Equals($toolBinPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "'$commandName' resolved outside the uv tool bin directory: $($command.Source)"
        }
        $installedCommands[$commandName] = $command.Source
    }

    Write-Host (Invoke-Utf8NativeCapture -FilePath $installedCommands["ccc-server"] -Arguments @("--version"))
    $script:CccVerified = $true
    Start-InstallStep "Desktop integration"
    Export-CccDesktopIcon `
        -DesktopCommand $installedCommands["ccc-desktop"] `
        -IconPath $iconPath
    Install-CccDesktopShortcuts `
        -DesktopCommand $installedCommands["ccc-desktop"] `
        -IconPath $iconPath
    $script:CccDesktopCommand = $installedCommands["ccc-desktop"]
    $script:CccIconPath = $iconPath
}

function Test-EquivalentPath {
    param(
        [string] $Left,
        [string] $Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    try {
        return [string]::Equals(
            [IO.Path]::GetFullPath($Left),
            [IO.Path]::GetFullPath($Right),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Install-CccDesktopShortcuts {
    param(
        [string] $DesktopCommand,
        [string] $IconPath
    )

    $shortcutPaths = @(
        (Join-Path $env:USERPROFILE "Desktop\Community Claude Code.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Community Claude Code.lnk")
    )
    foreach ($shortcutPath in $shortcutPaths) {
        Write-Host "+ create shortcut $(Format-Argument $shortcutPath) -> $(Format-Argument $DesktopCommand)"
    }
    if ($DryRun) {
        return
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcutPath in $shortcutPaths) {
        if (Test-Path -LiteralPath $shortcutPath) {
            try {
                $existingShortcut = $shell.CreateShortcut($shortcutPath)
                $isCccShortcut = Test-EquivalentPath -Left $existingShortcut.TargetPath -Right $DesktopCommand
            }
            catch {
                $isCccShortcut = $false
            }
            if (-not $isCccShortcut) {
                Write-Host "A shortcut not managed by Community Claude Code already exists at $shortcutPath; leaving it unchanged."
                continue
            }
        }
        $parent = Split-Path -Parent $shortcutPath
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $DesktopCommand
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.IconLocation = "$IconPath,0"
        $shortcut.Description = "Run Community Claude Code in the background"
        $shortcut.Save()
        if ($shortcutPath -eq $shortcutPaths[0]) { $script:DesktopReady = $true }
    }
}

function Show-InstallerNextSteps {
    Write-Host "`nCommunity Claude Code is installed and verified."
    Write-Host "The CCC proxy is running in the background."
    Write-Host "Claude Code is configured; run it with: claude"
    Write-Host "Claude Desktop is configured and ready to use."
    Write-Host "OpenCode serve runs in the background."
    if ($script:DesktopReady) {
        Write-Host "The Community Claude Code tray starts automatically at sign-in."
    }
    Write-Host "To change models or providers, edit $env:USERPROFILE\.ccc\.env or run ccc-doctor."
}

function Invoke-SelectedReleaseInstaller {
    param([hashtable] $InstallerArguments)

    try {
        if (-not $CccInstallVersion) {
            $releaseBase = "https://github.com/theRizwan/community-claude-code/releases"
            $response = Invoke-WebRequest -Uri "$releaseBase/latest" -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 5
            $selectedUrl = if ($response.BaseResponse.PSObject.Properties['ResponseUri']) {
                $response.BaseResponse.ResponseUri.AbsoluteUri
            } else { $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
            $prefix = "$releaseBase/tag/v"
            if (-not $selectedUrl.StartsWith($prefix, [StringComparison]::Ordinal)) { throw "GitHub returned an unexpected CCC release URL." }
            $CccInstallVersion = $selectedUrl.Substring($prefix.Length)
            if ($CccInstallVersion -cnotmatch $CccReleasePattern) { throw "GitHub did not return a canonical CCC release version." }
        }
        $text = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/theRizwan/community-claude-code/v$CccInstallVersion/scripts/install.ps1" -TimeoutSec 10 -MaximumRedirection 5
        if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) { throw "The installer for CCC $CccInstallVersion was empty or invalid." }
        $installer = [scriptblock]::Create($text)
    } catch {
        Write-Host "Retry: $(Get-InstallerRetryCommand)"
        throw
    }
    $previousContext = @{}
    foreach ($name in @('CCC_INSTALL_VERSION', '_CCC_INSTALLER_RELEASE')) {
        $previousContext[$name] = Get-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    try {
        $env:CCC_INSTALL_VERSION = $CccInstallVersion
        $env:_CCC_INSTALLER_RELEASE = $CccInstallVersion
        & $installer @InstallerArguments
    } finally {
        foreach ($name in $previousContext.Keys) {
            if ($null -ne $previousContext[$name]) { Set-Item -LiteralPath "Env:$name" -Value $previousContext[$name].Value }
            else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        }
    }
}

function Read-ToolchainRequirements {
    param([string] $Text)

    $section = ""
    $sections = @{}
    $values = @{}
    $number = '(0|[1-9][0-9]*)'
    $version = "$number\.$number\.$number"
    foreach ($rawLine in ($Text -split "`n")) {
        $line = $rawLine.Trim()
        if ($line.StartsWith('[')) {
            $section = ""
            if ($line -cmatch '^\[project\]\s*(#.*)?$') { $section = "project" }
            if ($line -cmatch '^\[tool\.uv\]\s*(#.*)?$') { $section = "uv" }
            if ($section) {
                if ($sections.ContainsKey($section)) { throw "Duplicate toolchain table." }
                $sections[$section] = $true
            }
            continue
        }
        if (($section -eq "project" -and $line -cmatch '^requires-python\s*=') -or
            ($section -eq "uv" -and $line -cmatch '^required-version\s*=')) {
            if ($values.ContainsKey($section)) { throw "Duplicate toolchain requirement." }
            $value = ($line -split '=', 2)[1].TrimStart()
            $operator = if ($section -eq "project") { "==" } else { ">=" }
            if ($value -cnotmatch ('^(?<quote>["''])' + $operator + '(?<version>' + $version + ')\k<quote>\s*(#.*)?$')) {
                throw "Invalid $section toolchain requirement."
            }
            $values[$section] = $Matches.version
        }
    }
    if (-not $values.ContainsKey("project") -or -not $values.ContainsKey("uv")) {
        throw "Missing Python or uv requirement in pyproject.toml."
    }
    return @{ Python = $values.project; Uv = $values.uv }
}

function Get-ReleaseToolchain {
    $metadataUrl = "https://raw.githubusercontent.com/theRizwan/community-claude-code/v$CccInstallVersion/pyproject.toml"
    $text = Invoke-RestMethod -Uri $metadataUrl -TimeoutSec 10 -MaximumRedirection 5 -ErrorAction Stop
    if ($text -isnot [string]) { throw "Invalid pyproject.toml response for CCC $CccInstallVersion." }
    return Read-ToolchainRequirements -Text $text
}

if ($Help) {
    Show-Usage
    return
}

if ($RemainingArgs.Count -gt 0) {
    Show-Usage
    throw "Unknown option: $($RemainingArgs -join ' ')"
}

if ($CccInstallVersion -and $CccInstallVersion -cnotmatch $CccReleasePattern) {
    throw "CCC_INSTALL_VERSION must be a canonical major.minor.patch release."
}

if ((-not [string]::IsNullOrWhiteSpace($TorchBackend)) -and (-not $VoiceLocal)) {
    throw "-TorchBackend requires -VoiceLocal."
}

if (-not $DryRun) {
    # A public pin requests a release; only the consumed marker skips dispatch.
    $installerRelease = [Environment]::GetEnvironmentVariable("_CCC_INSTALLER_RELEASE")
    if ($installerRelease -and $installerRelease -cne $CccInstallVersion) { throw "Invalid CCC release handoff." }
    Remove-Item Env:_CCC_INSTALLER_RELEASE -ErrorAction SilentlyContinue
    if (-not $installerRelease) {
        $installerParameters = @{} + $PSBoundParameters
        Invoke-SelectedReleaseInstaller -InstallerArguments $installerParameters
        return
    }
    try {
        $requirements = Get-ReleaseToolchain
    } catch {
        if ($CccInstallVersion) {
            Write-Host "Could not load toolchain requirements for CCC $CccInstallVersion."
            Write-Host "Retry: $(Get-InstallerRetryCommand)"
        }
        throw
    }
    # Windows on ARM emulates x64 for broader Python wheel support.
    $PythonRequest = "cpython-$($requirements.Python)-windows-x86_64-none"
    $MinUvVersion = $requirements.Uv
}
Initialize-InstallLog
$script:InstallSteps["Preflight"] = "Not attempted"
$installSucceeded = $false
$installError = $null
try {
    Start-InstallStep "Preflight"
    # Preserve the user's winning command before adding installer search paths.
    $script:OriginalOpenCode = Get-ApplicationCommand "opencode"
    $script:OriginalOpenCodeSearchPath = $env:Path
    Add-KnownBinDirectories
    Write-Step "Checking for running Community Claude Code processes"
    Assert-NoCccProcessesRunning

    $script:InstallSteps["uv"] = "Not attempted"
    $selectedAgents = @()
    foreach ($choice in @(
        @("Claude Code", $script:InstallClaudeCode), @("Codex", $script:InstallCodex),
        @("Pi", $script:InstallPi), @("OpenCode", $script:InstallOpenCode),
        @("Cline", $script:InstallCline), @("Hermes", $script:InstallHermes),
        @("DeepSeek Harness", $script:InstallDsh), @("Grok", $script:InstallGrok),
        @("Muse", $script:InstallMuse), @("Aider", $script:InstallAider),
        @("Antigravity CLI", $script:InstallAgy)
    )) {
        if ($choice[1]) {
            $script:InstallSteps[$choice[0]] = "Not attempted"
            $selectedAgents += $choice[0]
        }
    }
    foreach ($name in @("CCC package", "PATH configuration", "CCC verification", "Desktop integration", "Claude Desktop", "Claude integration", "Background services", "Startup configuration", "Claude Desktop launch")) {
        $script:InstallSteps[$name] = "Not attempted"
    }
    if ($script:EnableRtkHeadroom) {
        $script:InstallSteps["Headroom verification"] = "Not attempted"
        $script:InstallSteps["RTK configuration"] = "Not attempted"
        $script:InstallSteps["Headroom configuration"] = "Not attempted"
    }

    Write-Host "`nInstallation plan:"
    Write-Host "  Install or update Community Claude Code."
    Write-Host "  Verify or install: $($selectedAgents -join ', ')."
    Write-Host "  Install or verify Claude Desktop."
    Write-Host "  Configure Claude Code and Claude Desktop for the CCC proxy."
    Write-Host "  Start the CCC proxy, OpenCode serve, and free-model shim in the background."
    Write-Host "  Enable automatic startup at sign-in and open Claude Desktop."
    if ($VoiceLocal) { Write-Host "  Include local voice support." }
    if ($TorchBackend) { Write-Host "  PyTorch backend: $TorchBackend" }
    if ($script:EnableRtkHeadroom) { Write-Host "  Run RTK + Headroom setup for supported selected agents." }
    Write-Host "Press Ctrl+C to cancel. You can rerun the installer afterward."
    $script:InstallStageCount = $script:InstallSteps.Count - 1

    Confirm-SelectedPrerequisites

    Start-InstallStep "uv" "Ensuring uv $MinUvVersion or newer is installed"
    Ensure-Uv

    Ensure-SelectedCodingAgents

    Start-InstallStep "CCC package" "Installing or updating Community Claude Code"
    Install-CommunityClaudeCode

    Configure-AndConfirmCommunityClaudeCode

    Start-InstallStep "Claude Desktop" "Ensuring Claude Desktop is installed"
    Ensure-ClaudeDesktop

    Start-InstallStep "Claude integration" "Configuring Claude Code and Claude Desktop"
    Invoke-CccBootstrap -Arguments @("configure")

    Start-InstallStep "Background services" "Starting the CCC proxy, OpenCode serve, and free-model shim"
    Invoke-CccBootstrap -Arguments @("services")

    Start-InstallStep "Startup configuration" "Enabling automatic startup at sign-in"
    Install-CccStartupShortcut -DesktopCommand $script:CccDesktopCommand

    Start-InstallStep "Claude Desktop launch" "Opening Claude Desktop"
    Invoke-CccBootstrap -Arguments @("launch-desktop")

    if ($script:EnableRtkHeadroom) {
        Start-InstallStep "Headroom verification"
        Ensure-Headroom
        Start-InstallStep "RTK configuration"
        Configure-RtkForSelectedAgents
        Start-InstallStep "Headroom configuration"
        Configure-HeadroomForSelectedAgents
    }
    Complete-InstallStep
    $installSucceeded = $true
}
catch {
    $installError = $_
    Write-InstallLog $_.Exception.Message
    throw
}
finally {
    $cancelled = (-not $installSucceeded) -and ($null -eq $installError)
    if ($cancelled) { Complete-InstallStep "Cancelled" }
    elseif (-not $installSucceeded) { Complete-InstallStep "Failed" }
    Show-InstallReport -Succeeded $installSucceeded -Cancelled $cancelled
    if ($script:CccVerified) { Show-InstallerNextSteps }
}

if ($DryRun) { Write-Host "Dry run complete. No changes were made." }
