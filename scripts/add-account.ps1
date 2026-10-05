# Adds (or replaces) an account's long-lived token in tokens.json.
# Runs `claude setup-token`: a browser tab opens; sign in as the account you are adding and approve.
# The token is captured straight into tokens.json and never printed.
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Store = (Join-Path $HOME '.claude\account-switcher'),
  [string]$ClaudeExe = 'claude',
  [int]$WaitSeconds = 300
)
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[a-z0-9][a-z0-9_-]{0,30}$') { throw "Name must be lowercase letters, digits, - or _ (got '$Name')" }
New-Item -ItemType Directory -Force $Store | Out-Null
$raw = Join-Path $Store "setup-token-$Name.raw.txt"
$err = Join-Path $Store "setup-token-$Name.err.txt"
Remove-Item $raw, $err -ErrorAction SilentlyContinue

# Resolve the claude executable (PATH or an explicit path).
$exe = (Get-Command $ClaudeExe -ErrorAction SilentlyContinue).Source
if (-not $exe) { $exe = $ClaudeExe }
if (-not (Test-Path $exe)) { throw "claude executable not found: $ClaudeExe" }

# A scratch config dir keeps setup-token away from any existing login on this machine.
$cfg = Join-Path $env:TEMP "claude-account-switcher-setup-$Name"
New-Item -ItemType Directory -Force $cfg | Out-Null
$env:CLAUDE_CONFIG_DIR = $cfg
Remove-Item Env:\CLAUDE_CODE_OAUTH_TOKEN, Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_API_KEY, Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $exe -ArgumentList 'setup-token' -RedirectStandardOutput $raw -RedirectStandardError $err -PassThru -WindowStyle Hidden
Write-Host "Sign in as the '$Name' account in the browser tab that just opened, then approve. Waiting up to $WaitSeconds s..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$token = $null
while ((Get-Date) -lt $deadline) {
  if (Test-Path $raw) {
    $text = [string](Get-Content $raw -Raw -ErrorAction SilentlyContinue)
    if ($text) {
      $m = [regex]::Match($text, 'sk-ant-oat01-[A-Za-z0-9_\-]+')
      if ($m.Success) { $token = $m.Value; break }
    }
  }
  if ($p.HasExited -and -not (Test-Path $raw)) { break }
  Start-Sleep -Seconds 3
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $raw, $err -Force -ErrorAction SilentlyContinue
Remove-Item $cfg -Recurse -Force -ErrorAction SilentlyContinue
if (-not $token) { throw "No token captured for '$Name' (sign-in not completed?)" }

$tokensPath = Join-Path $Store 'tokens.json'
$tokens = [ordered]@{}
if (Test-Path $tokensPath) {
  $existing = Get-Content $tokensPath -Raw | ConvertFrom-Json
  foreach ($prop in $existing.PSObject.Properties) { $tokens[$prop.Name] = $prop.Value }
}
$now = [DateTime]::UtcNow
$tokens[$Name] = [ordered]@{ token = $token; createdAt = $now.ToString('o'); expiresAt = $now.AddDays(365).ToString('o') }
($tokens | ConvertTo-Json -Depth 4) | Set-Content -Path $tokensPath -Encoding ascii
$back = (Get-Content $tokensPath -Raw | ConvertFrom-Json).$Name
if ($back.token.Length -ne $token.Length) { throw "Read-back mismatch for '$Name'" }
Write-Host "Stored '$Name': token length $($back.token.Length), expires $("$($back.expiresAt)".Substring(0,10)). Accounts: $($tokens.Keys -join ', ')"
