#!/usr/bin/env bash
# Adds (or replaces) an account's long-lived token in tokens.json (macOS / Linux).
# Runs `claude setup-token` in a pseudo-terminal: a browser tab opens (or a sign-in URL is shown);
# sign in as the account you are adding and approve. If Claude Code asks you to paste a code back,
# paste it here as usual. The token is captured straight into tokens.json; on screen it is masked.
# Usage: scripts/add-account.sh <name> [--store DIR] [--claude PATH] [--wait SECONDS]
set -euo pipefail

NAME=""
STORE="$HOME/.claude/account-switcher"
CLAUDE_EXE="claude"
WAIT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --store) STORE="$2"; shift 2 ;;
    --claude) CLAUDE_EXE="$2"; shift 2 ;;
    --wait) WAIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) NAME="$1"; shift ;;
  esac
done
[ -n "$NAME" ] || { echo "usage: $0 <name> [--store DIR] [--claude PATH] [--wait SECONDS]" >&2; exit 2; }
if ! printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9_-]{0,30}$'; then
  echo "Name must be lowercase letters, digits, - or _ (got '$NAME')" >&2; exit 2
fi

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || { echo "python3 not found" >&2; exit 1; }

# Resolve the claude executable (PATH or an explicit path).
EXE="$(command -v "$CLAUDE_EXE" || true)"
[ -n "$EXE" ] || EXE="$CLAUDE_EXE"
[ -x "$EXE" ] || { echo "claude executable not found: $CLAUDE_EXE" >&2; exit 1; }

mkdir -p "$STORE"
chmod 700 "$STORE"

# A scratch config dir keeps setup-token away from any existing login on this machine.
CFG="$(mktemp -d "${TMPDIR:-/tmp}/claude-account-switcher-setup-$NAME.XXXXXX")"
trap 'rm -rf "$CFG"' EXIT
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

echo "Sign in as the '$NAME' account in the browser tab that opens (or at the URL shown), then approve."
echo "If Claude Code asks for a code, paste it here. Waiting up to $WAIT s..."

# The Python below runs setup-token on a pty (it prints nothing without one), passes your keystrokes
# through, shows its screen with the token masked, and writes the captured token into tokens.json.
CLAUDE_CONFIG_DIR="$CFG" "$PYTHON" - "$EXE" "$NAME" "$STORE/tokens.json" "$WAIT" <<'PY'
import datetime, fcntl, json, os, pty, re, select, signal, struct, sys, termios, time, tty

exe, name, tokens_path, wait = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
TOKEN = re.compile(rb"sk-ant-oat01-[A-Za-z0-9_\-]+")
PREFIX = b"sk-ant-oat01-"
MASK = b"sk-ant-oat01-[captured, not shown]"

pid, fd = pty.fork()
if pid == 0:
    os.execvp(exe, [exe, "setup-token"])

# Wide pty so the renderer never wraps the token across lines.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 220, 0, 0))

stdin_fd = sys.stdin.fileno()
old_attrs = None
if os.isatty(stdin_fd):
    old_attrs = termios.tcgetattr(stdin_fd)
    tty.setraw(stdin_fd)

captured = None
pending = b""        # output not yet shown (held back while it could be the start of a token)
deadline = time.time() + wait
exited = False
try:
    while True:
        if time.time() > deadline:
            break
        if exited and not pending:
            break
        rfds = [fd] + ([stdin_fd] if old_attrs is not None else [])
        ready, _, _ = select.select(rfds, [], [], 0.2)
        if fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if not data:
                exited = True
            else:
                m = TOKEN.search(data)
                if m and captured is None:
                    captured = m.group(0).decode()
                    deadline = min(deadline, time.time() + 3)   # let it finish drawing, then stop
                pending += data
        if stdin_fd in ready:
            try:
                k = os.read(stdin_fd, 1024)
            except OSError:
                k = b""
            if k:
                os.write(fd, k)
        if pending:
            shown = TOKEN.sub(MASK, pending)
            # Hold back a trailing fragment that might continue into a token in the next chunk.
            hold = 0
            if not shown.endswith(MASK):
                m2 = re.search(rb"sk-ant-oat01-[A-Za-z0-9_\-]*$", shown)
                if m2:
                    hold = len(m2.group(0))
                else:
                    for n in range(min(len(PREFIX) - 1, len(shown)), 0, -1):
                        if shown.endswith(PREFIX[:n]):
                            hold = n
                            break
            if hold and not exited:
                out, pending = shown[:-hold], shown[-hold:]
            else:
                out, pending = shown, b""
            if out:
                os.write(sys.stdout.fileno(), out)
finally:
    if old_attrs is not None:
        termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    os.close(fd)
    sys.stdout.write("\r\n")

if not captured:
    sys.exit("No token captured for '%s' (sign-in not completed?)" % name)

tokens = {}
if os.path.exists(tokens_path):
    with open(tokens_path, encoding="utf-8") as f:
        tokens = json.load(f)
now = datetime.datetime.now(datetime.timezone.utc)
tokens[name] = {
    "token": captured,
    "createdAt": now.isoformat(),
    "expiresAt": (now + datetime.timedelta(days=365)).isoformat(),
}
fdw = os.open(tokens_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fdw, "w", encoding="utf-8") as f:
    json.dump(tokens, f, indent=2)
    f.write("\n")
os.chmod(tokens_path, 0o600)
with open(tokens_path, encoding="utf-8") as f:
    back = json.load(f)[name]
if len(back["token"]) != len(captured):
    sys.exit("Read-back mismatch for '%s'" % name)
print("Stored '%s': token length %d, expires %s. Accounts: %s"
      % (name, len(back["token"]), back["expiresAt"][:10], ", ".join(sorted(tokens))))
PY
