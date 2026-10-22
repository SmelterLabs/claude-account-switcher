# Adds (or replaces) an account's long-lived token in tokens.json.
# Runs `claude setup-token`: a browser tab opens; sign in as the account you are adding and approve.
# The token is captured straight into tokens.json and never printed.
# -IsolatedBrowser opens the sign-in in a fresh, empty Chrome (or Edge) window instead of your usual
# browser, so it never mixes with the accounts you are signed into there; the window and its
# temporary profile are removed when the script ends.
param(
  [Parameter(Mandatory)][string]$Name,
  [string]$Store = (Join-Path $HOME '.claude\account-switcher'),
  [string]$ClaudeExe = 'claude',
  [int]$WaitSeconds = 300,
  [switch]$IsolatedBrowser,
  [string]$BrowserExe
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

# Isolated sign-in: Claude Code is handed a browser command that does nothing, and the sign-in link it
# prints is opened here in a throwaway profile inside the scratch config dir. (A .cmd cannot open the
# link itself: cmd.exe cuts the link at its first '&'.)
$profileDir = Join-Path $cfg 'browser-profile'
if ($IsolatedBrowser) {
  if (-not $BrowserExe) {
    $BrowserExe = @(
      "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if (-not $BrowserExe -or -not (Test-Path $BrowserExe)) { throw "-IsolatedBrowser needs Chrome or Edge; pass its path with -BrowserExe" }
  $noBrowser = Join-Path $cfg 'no-browser.cmd'
  Set-Content -Path $noBrowser -Value '@exit /b 0' -Encoding ascii
  $env:BROWSER = $noBrowser
}

$token = $null
try {
  $p = Start-Process -FilePath $exe -ArgumentList 'setup-token' -RedirectStandardOutput $raw -RedirectStandardError $err -PassThru -WindowStyle Hidden
  $where = if ($IsolatedBrowser) { 'the new browser window' } else { 'the browser tab that just opened' }
  Write-Host "Sign in as the '$Name' account in $where, then approve. Waiting up to $WaitSeconds s..."
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  $opened = $false
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $raw) {
      $text = [string](Get-Content $raw -Raw -ErrorAction SilentlyContinue)
      if ($text) {
        $m = [regex]::Match($text, 'sk-ant-oat01-[A-Za-z0-9_\-]+')
        if ($m.Success) { $token = $m.Value; break }
        if ($IsolatedBrowser -and -not $opened) {
          $u = [regex]::Match($text, 'https://[^\s\x07\x1b]*/oauth/authorize\?[^\s\x07\x1b]+')
          if ($u.Success) {
            Start-Process -FilePath $BrowserExe -ArgumentList "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', "`"$($u.Value)`""
            $opened = $true
          }
        }
      }
    }
    if ($p.HasExited -and -not (Test-Path $raw)) { break }
    Start-Sleep -Seconds $(if ($IsolatedBrowser -and -not $opened) { 1 } else { 3 })
  }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
} finally {
  if ($IsolatedBrowser) {
    # Close the throwaway window (found by its profile folder, so a browser that relaunched itself is caught too).
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" |
      Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileDir) } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
  }
  Remove-Item $raw, $err -Force -ErrorAction SilentlyContinue
  Remove-Item $cfg -Recurse -Force -ErrorAction SilentlyContinue
}
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
