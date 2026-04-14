#!/bin/sh

# Inline structured logger — same format as lib/log.sh.
log() {
  printf '%s %s %-16s %-14s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
}

if [ -x /usr/local/lib/claude-code-sandbox/enable-dnf ]; then
  if [ -n "${CLAUDE_ENABLE_DNF:-}" ]; then
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf --yes --purge
  else
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf --purge
  fi
fi

export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/.shrc" ] && . "$HOME/.shrc"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

CLAUDE_BIN="$HOME/.local/bin/claude-bin"
[ -x "$CLAUDE_BIN" ] || { log E run fail "claude binary not found at $CLAUDE_BIN"; exit 1; }

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1
export EDITOR=micro

exec "$CLAUDE_BIN" "$@"
