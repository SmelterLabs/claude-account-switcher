#!/usr/bin/env bash
# Installs claude-account-switcher for the current user on macOS or Linux:
#   1. copies the plugin and the relay into ~/.claude/account-switcher
#   2. adds CLAUDE_CODE_PLUGIN_DIRS and CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 to the env block of
#      ~/.claude/settings.json (backup kept)
#   3. registers the relay as a per-user service that starts at login and restarts on failure
#      (launchd LaunchAgent on macOS, systemd --user unit on Linux)
#   4. starts the relay now and verifies its heartbeat
# Idempotent: re-run after pulling a new version.
# Usage: scripts/install.sh [--store DIR] [--settings FILE] [--python PATH]
set -euo pipefail

STORE="$HOME/.claude/account-switcher"
SETTINGS="$HOME/.claude/settings.json"
PYTHON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "Unsupported OS '$OS'. On Windows use scripts\install.ps1." >&2; exit 1 ;;
esac

# Python 3 runs the relay (standard library only). Prefer Homebrew / python.org builds on macOS.
if [ -z "$PYTHON" ]; then
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$c" >/dev/null 2>&1; then PYTHON="$(command -v "$c")"; break; fi
  done
fi
[ -n "$PYTHON" ] || { echo "python3 not found; install Python 3 and re-run" >&2; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || { echo "$PYTHON is older than Python 3.8" >&2; exit 1; }

# 1. files (the store holds tokens, so it is private to this user)
mkdir -p "$STORE"
chmod 700 "$STORE"
rm -rf "$STORE/plugin"
mkdir -p "$STORE/plugin"
cp -R "$REPO/plugin/." "$STORE/plugin/"
cp "$REPO/relay/relay.py" "$STORE/relay.py"
echo "Installed files into $STORE"

# 2. settings.json env (keeps every other key; one timestamped backup)
PLUGIN_DIR="$STORE/plugin"
mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then cp "$SETTINGS" "$SETTINGS.bak-account-switcher-$(date +%Y%m%d-%H%M%S)"; fi
"$PYTHON" - "$SETTINGS" "$PLUGIN_DIR" <<'PY'
import json, os, sys
path, plugin_dir = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    data = json.loads(text) if text.strip() else {}
env = data.setdefault("env", {})
dirs = [d for d in (env.get("CLAUDE_CODE_PLUGIN_DIRS") or "").split(os.pathsep) if d and "account-switcher" not in d]
dirs.append(plugin_dir)
env["CLAUDE_CODE_PLUGIN_DIRS"] = os.pathsep.join(dirs)
# Hooks-module plugins are early access in the terminal CLI and need this flag; Claude Desktop sets it itself.
env["CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"] = "1"
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
with open(path, encoding="utf-8") as f:
    check = json.load(f)["env"]["CLAUDE_CODE_PLUGIN_DIRS"]
if plugin_dir not in check.split(os.pathsep):
    sys.exit("settings.json did not take CLAUDE_CODE_PLUGIN_DIRS")
print("settings.json env.CLAUDE_CODE_PLUGIN_DIRS = " + check + "; CLAUDE_CODE_ENABLE_FUNCTION_HOOKS = 1")
PY

# Stop a relay that is not under the service (hand-started, or left from an older install), by heartbeat pid.
stop_stray_relay() {
  [ -f "$STORE/relay.alive" ] || return 0
  local pid
  pid="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$STORE/relay.alive" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  if ps -o command= -p "$pid" 2>/dev/null | grep -q 'relay\.py'; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
}

# 3. per-user service, then 4. start it now
if [ "$OS" = "Linux" ]; then
  UNIT_NAME="claude-account-relay.service"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/$UNIT_NAME" <<UNIT
[Unit]
Description=Claude account-switcher relay (127.0.0.1:48620)

[Service]
ExecStart="$PYTHON" "$STORE/relay.py"
WorkingDirectory=$STORE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
  stop_stray_relay
  systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1
  systemctl --user start "$UNIT_NAME"
  echo "Registered systemd user unit $UNIT_NAME (starts at login, restarts on failure)"
  SERVICE_HINT="systemctl --user status $UNIT_NAME"
else
  LABEL="com.claude-account-switcher.relay"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$PYTHON")</string>
    <string>$(xml "$STORE/relay.py")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml "$STORE")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(xml "$STORE/relay.launchd.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$STORE/relay.launchd.log")</string>
</dict>
</plist>
PLIST
  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  stop_stray_relay
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    launchctl load -w "$PLIST"   # older launchctl, or no GUI session (e.g. over ssh)
  fi
  echo "Registered LaunchAgent $LABEL (starts at login, restarts on failure)"
  SERVICE_HINT="launchctl print $DOMAIN/$LABEL"
fi

# 4. verify the heartbeat
HB=""
for _ in $(seq 1 15); do
  sleep 1
  if HB="$("$PYTHON" - "$STORE/relay.alive" <<'PY'
import json, sys, time
try:
    h = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if time.time() - float(h.get("at", 0)) >= 30:
    sys.exit(1)
print("pid %s, port %s, accounts: %s" % (h.get("pid"), h.get("port"), ", ".join(h.get("accounts", [])) or "none"))
PY
  )"; then break; fi
  HB=""
done
if [ -z "$HB" ]; then
  echo "relay did not start (no fresh heartbeat in $STORE/relay.alive). Check: $SERVICE_HINT" >&2
  exit 1
fi
echo "Relay running: $HB"
echo "Done. Add accounts with scripts/add-account.sh <name>; open a new Claude Code session to load the plugin."
