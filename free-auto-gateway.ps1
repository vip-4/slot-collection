<#
.SYNOPSIS
  One-click start / switch-model / test helper for the FREE AUTO gateway (magpie).

.DESCRIPTION
  Wraps common operations against the local magpie gateway:
    - Auto-launch D:\magpie-windows-amd64.exe if port 3425 is not listening
    - Set session env vars OPENAI_BASE_URL / OPENAI_API_KEY / OPENAI_MODEL
    - List free/auto models, switch the active model, run a connectivity test

.PARAMETER Model
    Model id to activate (sets session OPENAI_MODEL). Default: kilo/kilo-auto/free

.PARAMETER Start
    Launch the gateway in the background if port 3425 is not already listening.

.PARAMETER Stop
    Stop the local gateway process (magpie).

.PARAMETER List
    List all free / auto models exposed by the gateway.

.PARAMETER Test
    Send one minimal request with the current OPENAI_MODEL to verify connectivity.

.PARAMETER ExePath
    Path to the magpie executable. Default: D:\magpie-windows-amd64.exe

.EXAMPLE
  .\free-auto-gateway.ps1 -Start -Model kilo/kilo-auto/free -Test
  .\free-auto-gateway.ps1 -List
  .\free-auto-gateway.ps1 -Model group/auto-beam-free -Test
  .\free-auto-gateway.ps1 -Stop
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [string]$Model = 'kilo/kilo-auto/free',
    [string]$ExePath = 'D:\magpie-windows-amd64.exe',
    [switch]$Start,
    [switch]$Stop,
    [switch]$List,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$BaseUrl   = 'http://127.0.0.1:3425/v1'
$ApiKey    = 'magpie'
$Port      = 3425

# Session env vars (visible to this process and child processes only)
$env:OPENAI_BASE_URL = $BaseUrl
$env:OPENAI_API_KEY  = $ApiKey
$env:OPENAI_MODEL    = $Model

function Test-Port {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $Port)
        $client.Close()
        return $true
    } catch { return $false }
}

function Start-Gateway {
    if (Test-Port) {
        Write-Host ('[OK] Gateway already listening on 127.0.0.1:{0}, nothing to start.' -f $Port) -ForegroundColor Green
        return
    }
    if (-not (Test-Path $ExePath)) {
        throw ('Gateway executable not found: {0} (use -ExePath to specify)' -f $ExePath)
    }
    Write-Host ('[*] Starting gateway: {0}' -f $ExePath) -ForegroundColor Cyan
    Start-Process -FilePath $ExePath -WindowStyle Hidden
    $t = 0
    while (-not (Test-Port) -and $t -lt 15) { Start-Sleep -Seconds 1; $t++ }
    if (Test-Port) {
        Write-Host ('[OK] Gateway ready: http://127.0.0.1:{0}/v1' -f $Port) -ForegroundColor Green
    } else {
        throw ('Gateway start timed out, check {0} manually' -f $ExePath)
    }
}

function Stop-Gateway {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $conn) { Write-Host '[*] No running gateway found.' -ForegroundColor Yellow; return }
    $pids = $conn.OwningProcess | Sort-Object -Unique
    foreach ($pid_ in $pids) {
        try { Stop-Process -Id $pid_ -Force; Write-Host ('[OK] Stopped PID {0}.' -f $pid_) -ForegroundColor Green }
        catch { Write-Warning ('Failed to stop PID {0}: {1}' -f $pid_, $_) }
    }
}

function Get-AutoFreeModels {
    try {
        $resp = Invoke-RestMethod -Uri ($BaseUrl + '/models') -Headers @{Authorization = ('Bearer {0}' -f $ApiKey) } -TimeoutSec 10
        $resp.data
    } catch { throw ('Failed to fetch model list: {0}' -f $_) }
}

function Test-Chat {
    $body = @{ model = $env:OPENAI_MODEL; messages = @(@{ role = 'user'; content = 'Reply with exactly: FREE AUTO OK' }); max_tokens = 2000 } | ConvertTo-Json -Depth 6
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $r = Invoke-RestMethod -Uri ($BaseUrl + '/chat/completions') -Method Post `
        -Headers @{ Authorization = ('Bearer {0}' -f $ApiKey); 'Content-Type' = 'application/json; charset=utf-8' } `
        -Body $bytes -TimeoutSec 120
    Write-Host ('[OK] model={0}  routed={1}  reply="{2}"' -f $env:OPENAI_MODEL, $r.model, $r.choices[0].message.content) -ForegroundColor Green
    if ($r.usage) { Write-Host ('      tokens: prompt={0} completion={1} total={2}' -f $r.usage.prompt_tokens, $r.usage.completion_tokens, $r.usage.total_tokens) }
}

# Main
if ($Stop) { Stop-Gateway; exit 0 }

if ($Start) { Start-Gateway }
elseif (-not (Test-Port)) {
    Write-Warning 'Port not listening and -Start not specified. Re-run with -Start to auto-launch the gateway.'
}

if ($List) {
    Get-AutoFreeModels | Where-Object { $_.id -match 'auto|free' } |
        Select-Object id, display_name, owned_by, max_input_tokens, max_output_tokens | Format-Table -AutoSize
}

if ($Test) { Test-Chat }

# Always echo current effective config
Write-Host ''
Write-Host '[Current session config]' -ForegroundColor Cyan
Write-Host ('  OPENAI_BASE_URL = {0}' -f $env:OPENAI_BASE_URL)
Write-Host ('  OPENAI_API_KEY  = {0}' -f $env:OPENAI_API_KEY)
Write-Host ('  OPENAI_MODEL    = {0}' -f $env:OPENAI_MODEL)
