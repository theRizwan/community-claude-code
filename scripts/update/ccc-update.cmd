@echo off
setlocal
set "CCC_UPDATE_CHECKER=%~dp0_ccc-update-check.exe"
(
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Continue'; $release = & $env:CCC_UPDATE_CHECKER --print-version; $status = $LASTEXITCODE; $ErrorActionPreference = 'Stop'; if ($status -isnot [int]) { throw 'CCC update preflight could not run.' }; if ($status -eq 0) { exit 0 }; if ($status -ne 10) { exit $status }; if ($release -isnot [string] -or $release -notmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') { throw 'Invalid CCC update version.' }; $env:CCC_INSTALL_VERSION = $release; $env:_CCC_INSTALLER_RELEASE = $release; & ([scriptblock]::Create((Invoke-RestMethod ('https://raw.githubusercontent.com/theRizwan/community-claude-code/v' + $release + '/scripts/install.ps1'))))" %*
  call exit /b %%errorlevel%%
)
