#!/bin/sh
[ -n "${CLAUDE_ENABLE_DNF:-}" ] && sudo /usr/local/lib/claude-code-sandbox/enable-dnf

export PATH="$HOME/.local/bin:$PATH"
[ -f "$HOME/.shrc" ] && . "$HOME/.shrc"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

CLAUDE_BIN="$HOME/.local/bin/claude-bin"
[ -x "$CLAUDE_BIN" ] || { echo "error: claude binary not found" >&2; exit 1; }

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export EDITOR=micro

exec "$CLAUDE_BIN" "$@"
