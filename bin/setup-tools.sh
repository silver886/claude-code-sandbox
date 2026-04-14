#!/bin/sh
# setup-tools.sh — extract tool archives and set up the claude binary.
# Usage: setup-tools.sh [--exec] <archive.tar.xz>...
#
# Extracts each archive into CLAUDE_BIN_DIR (default: $HOME/.local/bin),
# makes all files executable, then renames the claude binary so the
# shell wrapper (claude-wrapper.sh) can take over the "claude" name.
#
# With --exec, launches claude --dangerously-skip-permissions after setup.
set -eu

# Inline structured logger — same format and threshold semantics as
# lib/log.sh. $LOG_LEVEL inherited from the parent launcher.
log() {
  _t=2; case "${LOG_LEVEL:-W}" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"               in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  printf '%s %s %-16s %-14s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
}

LAUNCH=""
if [ "${1:-}" = "--exec" ]; then
  LAUNCH=1; shift
fi

BIN_DIR="${CLAUDE_BIN_DIR:-$HOME/.local/bin}"
log I archive extract "$BIN_DIR ($# archives)"
mkdir -p "$BIN_DIR"
for archive in "$@"; do
  tar -xJf "$archive" -C "$BIN_DIR/"
done
# Only chmod the known set extracted from the three tool archives —
# `chmod +x "$BIN_DIR"/*` would also flip mode on any pre-existing
# files in $BIN_DIR.
for _f in node rg micro claude-wrapper pnpm uv uvx claude; do
  [ -e "$BIN_DIR/$_f" ] && chmod +x "$BIN_DIR/$_f"
done
mv "$BIN_DIR/claude" "$BIN_DIR/claude-bin"
mv "$BIN_DIR/claude-wrapper" "$BIN_DIR/claude"
log I archive done "$BIN_DIR"

if [ -n "$LAUNCH" ]; then
  log I run launch "$BIN_DIR/claude --dangerously-skip-permissions"
  exec "$BIN_DIR/claude" --dangerously-skip-permissions
fi
