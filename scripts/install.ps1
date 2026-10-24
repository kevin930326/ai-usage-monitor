<#
.SYNOPSIS
  AI Usage Monitor - one-line install of the Windows collector (FR-48, ADR-0011, ADR-0013 section 7).

.DESCRIPTION
  irm https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.ps1 | iex

  With options (for example -WithQuota or -Uninstall):
  & ([scriptblock]::Create((irm https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.ps1))) -WithQuota

  1. Finds Python 3.10+ (py launcher, then PATH). If missing, offers to install it with winget
     (Python.Python.3.13, current user only; winget shows its own agreements).
  2. Downloads AIUsageMonitor-collector-<version>.zip from the same GitHub Release and checks its SHA-256
     (the expected value is written into this file when the release is built; SHA256SUMS lists it too).
  3. Installs to %LOCALAPPDATA%\AIUsageMonitor\app (the previous copy moves to app.old) and registers the
     scheduled task with collector\windows\install-task.ps1 (every 5 minutes, as you, no admin, tokens only).
  Nothing is uploaded. Data stays in %LOCALAPPDATA%\AIUsageMonitor. See docs/windows.md and docs/uninstall.md.

  This file is ASCII only: Windows PowerShell 5.1 decodes `irm` output without a charset as Latin-1,
  so Chinese text here would be garbled. The collector itself logs in UTF-8.

.PARAMETER WithQuota
  Also collect quota with the local claude / codex CLI (written to usage.json only, never uploaded).
.PARAMETER Uninstall
  Remove the scheduled task and %LOCALAPPDATA%\AIUsageMonitor\app. Data (history, logs, config) is kept.
.PARAMETER Version
  Version to install (default: the release this file came from).
.PARAMETER Sha256
  Expected SHA-256 of the zip (default: the value written in at release time).
.PARAMETER Zip
  Install from a local zip instead of downloading (testing). -Sha256 is still checked when given.
.PARAMETER NoTask
  Install the files but do not register the scheduled task (testing).
#>
param(
    [switch]$WithQuota,
    [switch]$Uninstall,
    [string]$Version,
    [string]$Sha256,
    [string]$Zip,
    [switch]$NoTask
)

function Install-AIUsageCollector {
    param([switch]$WithQuota, [switch]$Uninstall, [string]$Version, [string]$Sha256, [string]$Zip, [switch]$NoTask)
    # `throw` instead of `exit`: with `irm | iex` an exit would close the user's PowerShell window
    $ErrorActionPreference = 'Stop'
    $ReleaseVersion = '__VERSION__'
    $ReleaseSha256 = '__ZIP_SHA256__'
    $Repo = 'kevin930326/ai-usage-monitor'
    $DataDir = Join-Path $env:LOCALAPPDATA 'AIUsageMonitor'
    $AppDir = Join-Path $DataDir 'app'
    $OldDir = Join-Path $DataDir 'app.old'
    $TaskPath = '\AIUsageMonitor\'
    $TaskName = 'Collector'

    if ($Uninstall) {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
            Write-Host "Removed the scheduled task $TaskPath$TaskName"
        } else {
            Write-Host 'No scheduled task to remove.'
        }
        foreach ($dir in @($AppDir, $OldDir)) {
            if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
        }
        Write-Host "Removed the program files. Your data is kept in $DataDir (delete it yourself if you no longer need it)."
        return
    }

    if (-not $Version) { $Version = $ReleaseVersion }
    if (-not $Sha256 -and $Version -eq $ReleaseVersion) { $Sha256 = $ReleaseSha256 }
    if ($Version -like '*__VERSION__*' -and -not $Zip) {
        throw 'This copy of install.ps1 has no version. Download it from a GitHub Release (see docs/windows.md), or pass -Version and -Sha256.'
    }
    if ($Version -and $Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' -and $Version -notlike '*__VERSION__*') {
        throw "Version format is not valid: $Version"
    }
    if ($Sha256 -like '*__ZIP_SHA256__*') { $Sha256 = '' }
    if (-not $Zip -and $Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Missing the expected SHA-256 for the download (-Sha256).'
    }

    # ---------- 1. Python ----------
    function Find-Python {
        $candidates = @()
        $launcher = Get-Command py -ErrorAction SilentlyContinue
        if ($launcher) {
            $p = (& $launcher.Source -3 -c 'import sys; print(sys.executable)' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $p) { $candidates += $p.Trim() }
        }
        $found = Get-Command python -CommandType Application -ErrorAction SilentlyContinue
        if ($found) { $candidates += $found.Source }
        $candidates += Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python3*\python.exe') -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | ForEach-Object { $_.FullName }
        foreach ($c in $candidates) {
            # The Microsoft Store alias (WindowsApps) has no stable pythonw.exe: skip it
            if (-not $c -or $c -like '*\WindowsApps\*' -or -not (Test-Path $c)) { continue }
            & $c -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path (Split-Path -Parent $c) 'pythonw.exe'))) { return $c }
        }
        return $null
    }
    $Python = Find-Python
    if (-not $Python) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'Python 3.10 or later was not found, and winget is not available. Install Python from https://www.python.org/downloads/windows/ (check "py launcher"), then run this again.'
        }
        $answer = Read-Host 'Python 3.10 or later was not found. Install Python 3.13 for this user with winget now? [Y/n]'
        if ($answer -and $answer -notmatch '^[Yy]') { throw 'Cancelled. Install Python 3.10 or later, then run this again.' }
        & $winget.Source install --id Python.Python.3.13 --exact --scope user --source winget
        if ($LASTEXITCODE -ne 0) { throw "winget could not install Python (exit code $LASTEXITCODE)." }
        $Python = Find-Python
        if (-not $Python) { throw 'Python was installed but could not be found. Open a new PowerShell window and run this again.' }
    }
    Write-Host "OK  Python: $Python"

    # ---------- 2. Download and verify ----------
    # Stage next to the install folder (same volume): the final moves are renames, not copies
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $Work = Join-Path $DataDir ('.install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $Work | Out-Null
    try {
        if ($Zip) {
            $ZipPath = (Resolve-Path $Zip).Path
        } else {
            $ZipName = "AIUsageMonitor-collector-$Version.zip"
            $Url = "https://github.com/$Repo/releases/download/v$Version/$ZipName"
            $ZipPath = Join-Path $Work $ZipName
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Host "Downloading $ZipName ..."
            $ProgressPreference = 'SilentlyContinue'  # the progress bar makes Invoke-WebRequest very slow on 5.1
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $ZipPath
        }
        if ($Sha256) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $ZipPath).Hash
            if ($actual -ne $Sha256.ToUpperInvariant()) {
                throw "SHA-256 mismatch: expected $($Sha256.ToLowerInvariant()), got $($actual.ToLowerInvariant()). Nothing was installed."
            }
            Write-Host 'OK  SHA-256 matches'
        }
        $Stage = Join-Path $Work 'app'
        Expand-Archive -Path $ZipPath -DestinationPath $Stage
        foreach ($required in @('collector\usage_collector\__main__.py', 'collector\windows\install-task.ps1', 'collector\scripts\update-config.py')) {
            if (-not (Test-Path (Join-Path $Stage $required))) { throw "The zip is missing $required. Nothing was installed." }
        }

        # ---------- 3. Install ----------
        # A running collector keeps app\collector as its working directory: stop it and wait before moving
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
            for ($i = 0; $i -lt 30; $i++) {
                if ((Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State -ne 'Running') { break }
                Start-Sleep -Seconds 1
            }
        }
        if (Test-Path $OldDir) { Remove-Item -Recurse -Force $OldDir }
        if (Test-Path $AppDir) {
            $moved = $false
            for ($i = 0; $i -lt 15 -and -not $moved; $i++) {
                try { Move-Item $AppDir $OldDir -ErrorAction Stop; $moved = $true } catch { Start-Sleep -Seconds 1 }
            }
            if (-not $moved) { throw "Could not move the previous copy in $AppDir (still in use). Nothing was changed; try again in a minute." }
        }
        try {
            Move-Item $Stage $AppDir -ErrorAction Stop
        } catch {
            # Put the previous copy back so the existing task keeps working
            if ((Test-Path $OldDir) -and -not (Test-Path $AppDir)) { Move-Item $OldDir $AppDir }
            throw "Could not install to ${AppDir}: $_"
        }
        Write-Host "OK  Installed to $AppDir"
    } finally {
        if (Test-Path $Work) { Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue }
    }

    if ($NoTask) { return }
    $installTask = Join-Path $AppDir 'collector\windows\install-task.ps1'
    if ($WithQuota) { & $installTask -Python $Python -WithQuota } else { & $installTask -Python $Python }
    Write-Host ''
    Write-Host 'Done. The collector runs every 5 minutes while you are signed in. Remove it with:'
    Write-Host '  & ([scriptblock]::Create((irm https://github.com/kevin930326/ai-usage-monitor/releases/latest/download/install.ps1))) -Uninstall'
}

# Explicit arguments rather than @PSBoundParameters: with `irm | iex` the parameters are simply unset
Install-AIUsageCollector -WithQuota:$WithQuota -Uninstall:$Uninstall -Version $Version -Sha256 $Sha256 -Zip $Zip -NoTask:$NoTask
