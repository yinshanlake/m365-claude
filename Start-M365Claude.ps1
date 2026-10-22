#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$installRoot = $PSScriptRoot
$Model = $null
$modelSpecified = $false
$NoMcp = $false
$Directory = $null
$BuiltInTools = 'default'
$nativeArguments = [System.Collections.Generic.List[string]]::new()
# Advanced PowerShell binding consumes native --verbose and --debug flags.
# Parse only this launcher's four options and preserve all native arguments.
for ($index = 0; $index -lt $args.Count; $index++) {
    $argument = [string]$args[$index]
    if ($argument -eq '-NoMcp') { $NoMcp = $true; continue }
    if ($argument -in @('-Model', '-Directory', '-BuiltInTools')) {
        $index++
        if ($index -ge $args.Count) { throw ('Missing value for ' + $argument) }
        $value = [string]$args[$index]
        switch ($argument) {
            '-Model' { $Model = $value; $modelSpecified = $true }
            '-Directory' { $Directory = $value }
            '-BuiltInTools' { $BuiltInTools = $value }
        }
    } else { $nativeArguments.Add($argument) }
}
$ClaudeArguments = $nativeArguments.ToArray()
$catalog = Get-Content -LiteralPath (Join-Path $installRoot 'cli\models.json') -Raw | ConvertFrom-Json
if ($modelSpecified -and $Model -notin $catalog.models.id) { throw ('Unsupported M365 route: ' + $Model) }
$claudeProgram = if ($env:M365_CLAUDE_EXE) { $env:M365_CLAUDE_EXE } else { (Get-Command claude.exe -ErrorAction Stop).Source }
if (-not (Test-Path -LiteralPath $claudeProgram)) { throw 'Claude Code is not installed at the configured path.' }

if ($ClaudeArguments -contains '--version' -or $ClaudeArguments -contains '--help') {
    & $claudeProgram @ClaudeArguments
    exit $LASTEXITCODE
}

foreach ($serviceName in @('CliProxy', 'ClaudeRouter')) {
    & (Join-Path $installRoot 'Manage-Proxies.ps1') -Action Start -Service $serviceName | Out-Null
}
$deadline = [DateTime]::UtcNow.AddSeconds(20)
do {
    $ready = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -in @(4144, 4145) })
    if ($ready.Count -eq 2) { break }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)
if ($ready.Count -ne 2) { throw 'The local CLI services did not start. Check the CliProxy and ClaudeRouter logs in runtime/.' }

$keyPath = Join-Path $installRoot '.local\claude-router-api-key.txt'
$configDir = Join-Path $installRoot '.local\claude-state'
$mcpPath = Join-Path $installRoot '.local\claude-mcp.json'
$environment = @{
    ANTHROPIC_BASE_URL = 'http://127.0.0.1:4145'
    ANTHROPIC_API_KEY = $null
    ANTHROPIC_MODEL = $null
    ANTHROPIC_CUSTOM_HEADERS = $null
    ANTHROPIC_DEFAULT_MODEL = $catalog.default
    ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet'
    ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus'
    ANTHROPIC_DEFAULT_HAIKU_MODEL = $catalog.default
    ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME = 'M365 helper (GPT 5.5 Think Deeper)'
    ANTHROPIC_DEFAULT_FABLE_MODEL = $null
    ANTHROPIC_SMALL_FAST_MODEL = $null
    ANTHROPIC_CUSTOM_MODEL_OPTION = $null
    ANTHROPIC_AUTH_TOKEN = (Get-Content -LiteralPath $keyPath -Raw).Trim()
    CLAUDE_CODE_OAUTH_TOKEN = $null
    CLAUDE_CODE_USE_BEDROCK = $null
    CLAUDE_CODE_USE_VERTEX = $null
    CLAUDE_CODE_USE_FOUNDRY = $null
    CLAUDE_CODE_SUBAGENT_MODEL = $null
    CLAUDE_CONFIG_DIR = $configDir
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'
    ENABLE_TOOL_SEARCH = 'true'
    API_TIMEOUT_MS = '240000'
}
$previousEnvironment = @{}
$originalDirectory = Get-Location
$exitCode = 1
try {
    foreach ($name in $environment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
    }
    if ($Directory) { Set-Location -LiteralPath $Directory }
    $systemPrompt = Get-Content -LiteralPath (Join-Path $installRoot 'cli\agent-system-prompt.md') -Raw
    $systemPrompt += "`nWorking directory: " + (Get-Location).Path
    $arguments = @('--tools', $BuiltInTools, '--system-prompt', $systemPrompt)
    if ($modelSpecified) {
        $selected = $catalog.models | Where-Object id -EQ $Model
        $arguments += @('--model', ($selected.clientModel ?? $Model))
    }
    if (-not $NoMcp) {
        if (-not (Test-Path -LiteralPath $mcpPath)) { throw 'The dedicated MCP configuration is missing.' }
        $arguments += @('--mcp-config', $mcpPath)
    }
    $arguments += '--strict-mcp-config'
    $modelLabel = if ($Model) { $Model } else { 'saved selection or ' + $catalog.default }
    [Console]::Error.WriteLine(('M365 Claude Code | model: ' + $modelLabel + ' | MCP: ' + $(if ($NoMcp) { 'off' } else { 'on' })))
    & $claudeProgram @arguments @ClaudeArguments
    $exitCode = $LASTEXITCODE
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
    Set-Location -LiteralPath $originalDirectory.Path
}
exit $exitCode
