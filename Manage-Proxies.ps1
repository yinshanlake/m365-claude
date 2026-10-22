#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status')]
    [string]$Action = 'Status',
    [ValidateSet('All', 'Copilot2API', 'CopilotProxy', 'CliProxy', 'ClaudeRouter')]
    [string]$Service = 'All'
)

$ErrorActionPreference = 'Stop'
$installRoot = $PSScriptRoot
$runtimeDir = Join-Path $installRoot 'runtime'
$secretDir = Join-Path $installRoot '.local'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null

$services = @(
    @{ Name = 'Copilot2API'; Directory = 'M365-Copilot2API'; Port = 4141 },
    @{ Name = 'CopilotProxy'; Directory = 'm365-copilot-proxy'; Port = 4143 },
    @{ Name = 'CliProxy'; Directory = 'm365-copilot-proxy'; Port = 4144 },
    @{ Name = 'ClaudeRouter'; Directory = 'cli'; Port = 4145 }
)

foreach ($entry in $services) {
    if ($Service -ne 'All' -and $Service -ne $entry.Name) { continue }
    $repoDir = Join-Path $installRoot $entry.Directory
    $statePath = Join-Path $runtimeDir ($entry.Name + '.process.json')
    $stdoutPath = Join-Path $runtimeDir ($entry.Name + '.stdout.log')
    $stderrPath = Join-Path $runtimeDir ($entry.Name + '.stderr.log')
    $ownedProcess = $null
    if (Test-Path -LiteralPath $statePath) {
        $savedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $candidate = Get-Process -Id $savedState.ProcessId -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.Path -eq $savedState.ExecutablePath -and
            $candidate.StartTime.ToUniversalTime().Ticks.ToString() -eq $savedState.StartTimeTicks) {
            $ownedProcess = $candidate
        }
    }

    if ($Action -eq 'Stop') {
        if ($ownedProcess) {
            Stop-Process -Id $ownedProcess.Id
            Wait-Process -Id $ownedProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
            Write-Output ($entry.Name + ': stopped process ' + $ownedProcess.Id)
        } else {
            Write-Output ($entry.Name + ': already stopped')
        }
        continue
    }

    if ($Action -eq 'Start' -and -not $ownedProcess) {
        $listener = Get-NetTCPConnection -LocalPort $entry.Port -State Listen -ErrorAction SilentlyContinue
        if ($listener) { throw ('Port ' + $entry.Port + ' is already occupied; no process was replaced.') }
        $launchEnv = @{}
        $launchArgs = @()
        if ($entry.Name -eq 'Copilot2API') {
            $program = Join-Path $repoDir 'm365-copilot2api.exe'
            $dataDir = Join-Path $repoDir 'data'
            $passwordPath = Join-Path $secretDir 'copilot2api-admin-password.txt'
            if (-not (Test-Path -LiteralPath $passwordPath)) {
                throw ('Administrator password file is missing: ' + $passwordPath)
            }
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
            $launchEnv = @{
                M365_LISTEN = '127.0.0.1:4141'
                M365_DATA_DIR = $dataDir
                M365_CONFIG = (Join-Path $dataDir 'accounts.json')
                M365_TOKEN_CACHE = (Join-Path $dataDir 'token-cache.json')
                M365_SESSION_CACHE = (Join-Path $dataDir 'sessions.json')
                M365_CONVERSATION_CACHE = (Join-Path $dataDir 'conversations.json')
                M365_API_KEYS = (Join-Path $dataDir 'api-keys.json')
                M365_ADMIN_PASSWORD_BOOTSTRAP_FILE = $passwordPath
                M365_REQUIRE_STRONG_ADMIN_PASSWORD = '1'
                M365_AUTO_CLEANUP = 'off'
            }
        } elseif ($entry.Name -eq 'ClaudeRouter') {
            $program = (Get-Command node.exe -ErrorAction Stop).Source
            $entryPoint = Join-Path $repoDir 'm365-anthropic.cjs'
            $keyPath = Join-Path $secretDir 'claude-router-api-key.txt'
            if (-not (Test-Path -LiteralPath $keyPath)) { throw 'The Claude adapter key is missing.' }
            $launchArgs = @(('"' + $entryPoint + '"'))
            $launchEnv = @{
                M365_CLAUDE_ROUTER_KEY = (Get-Content -LiteralPath $keyPath -Raw).Trim()
            }
        } else {
            $program = (Get-Command node.exe -ErrorAction Stop).Source
            $entryPoint = Join-Path $repoDir 'packages\proxy\bin\m365-proxy.mjs'
            $builtServer = Join-Path $repoDir 'packages\proxy\.output\server\index.mjs'
            if (-not (Test-Path -LiteralPath $builtServer)) { throw 'CopilotProxy has not been built.' }
            $launchArgs = @(('"' + $entryPoint + '"'), $entry.Port.ToString())
            $launchEnv = @{
                HOST = '127.0.0.1'
                NITRO_HOST = '127.0.0.1'
                M365_ENABLE_INTERACTIVE_APPROVAL = '1'
                M365_NO_INTERACTIVE = '0'
                M365_INTERACTIVE_TIMEOUT_MS = '1800000'
                M365_LOGIN_LOCALE = 'en-US'
                M365_LOGIN_TIMEZONE = $(if ($env:M365_LOGIN_TIMEZONE) { $env:M365_LOGIN_TIMEZONE } else { 'UTC' })
                M365_HOST_SHELL = $null
                CHROMIUM_PATH = $(if ($env:M365_CHROME_PATH) { $env:M365_CHROME_PATH } else { 'C:/Program Files/Google/Chrome/Application/chrome.exe' })
            }
            if ($entry.Name -eq 'CliProxy') {
                $launchEnv.M365_HOST_SHELL = 'bash'
                $launchEnv.M365_FRAMING_VARIANT = 'relay'
                $launchEnv.M365_FORCE_AGENT = '0'
            }
            if (-not (Test-Path -LiteralPath $launchEnv.CHROMIUM_PATH)) { throw 'Google Chrome executable was not found.' }
        }
        if (-not (Test-Path -LiteralPath $program)) { throw ('Executable is missing: ' + $program) }
        $startOptions = @{
            FilePath = $program
            WorkingDirectory = $repoDir
            Environment = $launchEnv
            WindowStyle = 'Hidden'
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
            PassThru = $true
        }
        if ($launchArgs.Count -gt 0) { $startOptions.ArgumentList = $launchArgs }
        $ownedProcess = Start-Process @startOptions
        @{
            ProcessId = $ownedProcess.Id
            ExecutablePath = $program
            StartTimeTicks = $ownedProcess.StartTime.ToUniversalTime().Ticks.ToString()
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
        Write-Output ($entry.Name + ': started process ' + $ownedProcess.Id)
    }

    $listener = Get-NetTCPConnection -LocalPort $entry.Port -State Listen -ErrorAction SilentlyContinue
    $status = if (-not $ownedProcess) { 'Stopped' } elseif ($listener.OwningProcess -contains $ownedProcess.Id) { 'Listening' } else { 'Starting or waiting for Microsoft sign-in' }
    [pscustomobject]@{
        Service = $entry.Name
        Status = $status
        ProcessId = if ($ownedProcess) { $ownedProcess.Id } else { $null }
        URL = ('http://127.0.0.1:' + $entry.Port)
        ErrorLog = $stderrPath
    } | Format-List
}
