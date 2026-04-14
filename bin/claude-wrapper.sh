#!/bin/sh

# Inline structured logger — same format and threshold semantics as
# lib/log.sh. $LOG_LEVEL inherited from the launcher's container env.
log() {
  _t=2; case "${LOG_LEVEL:-W}" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"               in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  printf '%s %s %-16s %-14s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
}

if [ -x /usr/local/lib/claude-code-sandbox/enable-dnf ]; then
  # Pass log level as an explicit arg rather than a preserved env
  # var. Fedora sudoers `env_check` blocks unknown env vars even
  # with --preserve-env=, and adding LOG_LEVEL to env_keep would
  # widen the bootstrap sudoers rule unnecessarily.
  _DNF_LVL="--log-level ${LOG_LEVEL:-W}"
  if [ -n "${CLAUDE_ENABLE_DNF:-}" ]; then
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf $_DNF_LVL --yes --purge
  else
    sudo /usr/local/lib/claude-code-sandbox/enable-dnf $_DNF_LVL --purge
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
