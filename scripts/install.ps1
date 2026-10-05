# Installs claude-account-switcher for the current Windows user:
#   1. copies the plugin and the relay into ~/.claude/account-switcher
#   2. adds CLAUDE_CODE_PLUGIN_DIRS to the env block of ~/.claude/settings.json (backup kept)
#   3. registers the per-user scheduled task ClaudeAccountRelay (starts at logon, self-recovers)
#   4. starts the relay now and verifies its heartbeat
# Idempotent: re-run after pulling a new version.
param(
  [string]$Store = (Join-Path $HOME '.claude\account-switcher'),
  [string]$Settings = (Join-Path $HOME '.claude\settings.json'),
  [string]$Python = (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\pythonw.exe')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path $Python)) { $Python = (Get-Command pythonw -ErrorAction SilentlyContinue).Source }
if (-not $Python) { throw "pythonw.exe not found; install Python 3 and re-run" }

# 1. files
New-Item -ItemType Directory -Force "$Store\plugin" | Out-Null
Copy-Item "$repo\plugin\*" "$Store\plugin" -Recurse -Force
Copy-Item "$repo\relay\relay.py" "$Store\relay.py" -Force
Write-Host "Installed files into $Store"

# 2. settings.json env (keeps every other key; one timestamped backup)
if (Test-Path $Settings) {
  Copy-Item $Settings "$Settings.bak-account-switcher-$(Get-Date -Format yyyyMMdd-HHmmss)"
  $json = Get-Content $Settings -Raw | ConvertFrom-Json
} else { $json = [pscustomobject]@{} }
if (-not $json.env) { $json | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
$pluginDir = "$Store\plugin"
$existing = $json.env.CLAUDE_CODE_PLUGIN_DIRS
$dirs = @()
if ($existing) { $dirs = $existing -split ';' | Where-Object { $_ -and ($_ -notmatch 'account-switcher') } }
$dirs += $pluginDir
$json.env | Add-Member -NotePropertyName CLAUDE_CODE_PLUGIN_DIRS -NotePropertyValue ($dirs -join ';') -Force
($json | ConvertTo-Json -Depth 20) | Set-Content -Path $Settings -Encoding utf8
$check = (Get-Content $Settings -Raw | ConvertFrom-Json).env.CLAUDE_CODE_PLUGIN_DIRS
if ($check -notmatch [regex]::Escape($pluginDir)) { throw "settings.json did not take CLAUDE_CODE_PLUGIN_DIRS" }
Write-Host "settings.json env.CLAUDE_CODE_PLUGIN_DIRS = $check"

# 3. scheduled task (logon + 5-minute recovery; a second start exits at once because the port is held)
$taskName = 'ClaudeAccountRelay'
$action = New-ScheduledTaskAction -Execute $Python -Argument "`"$Store\relay.py`"" -WorkingDirectory $Store
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$recover = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($logon, $recover) -Settings $taskSettings -Principal $principal -Force | Out-Null
Write-Host "Registered scheduled task $taskName"

# 4. start now and verify the heartbeat (stop a hand-started relay first, by pid file)
$pidFile = "$Store\relay.pid"
if (Test-Path $pidFile) { $old = Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue; if ($old -and $old.ProcessName -match '^python') { Stop-Process -Id $old.Id -Force; Start-Sleep 1 }; Remove-Item $pidFile -Force }
Start-ScheduledTask -TaskName $taskName
$ok = $false
for ($i = 0; $i -lt 10; $i++) { Start-Sleep 1; if (Test-Path "$Store\relay.alive") { $hb = Get-Content "$Store\relay.alive" -Raw | ConvertFrom-Json; if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $hb.at) -lt 30) { $ok = $true; break } } }
if (-not $ok) { throw "relay did not start (no fresh heartbeat in $Store\relay.alive)" }
Write-Host "Relay running: pid $($hb.pid), port $($hb.port), accounts: $($hb.accounts -join ', ')"
Write-Host "Done. Add accounts with scripts\add-account.ps1 -Name <name>; open a new Claude Code session to load the plugin."
