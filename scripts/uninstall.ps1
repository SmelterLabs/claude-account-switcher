# Removes the scheduled task and the settings.json entry. Tokens are kept unless -PurgeTokens.
param(
  [string]$Store = (Join-Path $HOME '.claude\account-switcher'),
  [string]$Settings = (Join-Path $HOME '.claude\settings.json'),
  [switch]$PurgeTokens
)
$ErrorActionPreference = 'Continue'
Unregister-ScheduledTask -TaskName 'ClaudeAccountRelay' -Confirm:$false -ErrorAction SilentlyContinue
if (Test-Path "$Store\relay.alive") { $hb = Get-Content "$Store\relay.alive" -Raw | ConvertFrom-Json; $p = Get-Process -Id $hb.pid -ErrorAction SilentlyContinue; if ($p -and $p.ProcessName -match '^python') { Stop-Process -Id $p.Id -Force } }
if (Test-Path $Settings) {
  $json = Get-Content $Settings -Raw | ConvertFrom-Json
  if ($json.env -and $json.env.CLAUDE_CODE_PLUGIN_DIRS) {
    $dirs = $json.env.CLAUDE_CODE_PLUGIN_DIRS -split ';' | Where-Object { $_ -and ($_ -notmatch 'account-switcher') }
    if ($dirs) { $json.env.CLAUDE_CODE_PLUGIN_DIRS = ($dirs -join ';') } else { $json.env.PSObject.Properties.Remove('CLAUDE_CODE_PLUGIN_DIRS') }
    ($json | ConvertTo-Json -Depth 20) | Set-Content -Path $Settings -Encoding utf8
  }
}
Remove-Item "$Store\plugin" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$Store\relay.py", "$Store\relay.alive", "$Store\relay.pid" -Force -ErrorAction SilentlyContinue
if ($PurgeTokens) { Remove-Item "$Store\tokens.json" -Force -ErrorAction SilentlyContinue }
Write-Host "Uninstalled. Tokens $(if ($PurgeTokens) {'removed'} else {'kept in ' + $Store})."
