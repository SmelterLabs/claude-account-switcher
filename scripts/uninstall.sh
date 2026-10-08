#!/usr/bin/env bash
# Removes the relay service and the settings.json entry (macOS / Linux). Tokens are kept unless --purge-tokens.
# Usage: scripts/uninstall.sh [--store DIR] [--settings FILE] [--purge-tokens]
set -uo pipefail

STORE="$HOME/.claude/account-switcher"
SETTINGS="$HOME/.claude/settings.json"
PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --purge-tokens) PURGE=1; shift ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
PYTHON="$(command -v python3 || true)"

# 1. service
case "$(uname -s)" in
  Linux)
    UNIT_NAME="claude-account-relay.service"
    systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"
    systemctl --user daemon-reload 2>/dev/null || true
    ;;
  Darwin)
    LABEL="com.claude-account-switcher.relay"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
    ;;
esac

# 2. any relay still running (by heartbeat pid, only if it really is relay.py)
if [ -f "$STORE/relay.alive" ] && [ -n "$PYTHON" ]; then
  pid="$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$STORE/relay.alive" 2>/dev/null || true)"
  if [ -n "$pid" ] && ps -o command= -p "$pid" 2>/dev/null | grep -q 'relay\.py'; then kill "$pid" 2>/dev/null || true; fi
fi

# 3. settings.json: drop our entry from CLAUDE_CODE_PLUGIN_DIRS, keep everything else
if [ -f "$SETTINGS" ] && [ -n "$PYTHON" ]; then
  "$PYTHON" - "$SETTINGS" <<'PY' || echo "warning: could not update $SETTINGS; remove the account-switcher entry from env.CLAUDE_CODE_PLUGIN_DIRS by hand" >&2
import json, os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
env = data.get("env") or {}
if "CLAUDE_CODE_PLUGIN_DIRS" in env:
    dirs = [d for d in env["CLAUDE_CODE_PLUGIN_DIRS"].split(os.pathsep) if d and "account-switcher" not in d]
    if dirs:
        env["CLAUDE_CODE_PLUGIN_DIRS"] = os.pathsep.join(dirs)
    else:
        del env["CLAUDE_CODE_PLUGIN_DIRS"]
        # No other plugin folders left, so the hooks-module flag the installer added is not needed either.
        env.pop("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS", None)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
fi

# 4. files
rm -rf "$STORE/plugin"
rm -f "$STORE/relay.py" "$STORE/relay.alive" "$STORE/relay.pid" "$STORE/relay.launchd.log"
if [ "$PURGE" = 1 ]; then
  rm -f "$STORE/tokens.json" "$STORE/relay.log"
  rmdir "$STORE" 2>/dev/null || true
  echo "Uninstalled. Tokens removed."
else
  echo "Uninstalled. Tokens kept in $STORE."
fi
