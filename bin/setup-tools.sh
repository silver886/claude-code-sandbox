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

# Inline structured logger — same format, threshold, and color
# semantics as lib/log.sh. $LOG_LEVEL inherited from the parent
# launcher. Colors disabled when $NO_COLOR is set or stderr is not
# a tty (piped/captured), so log files never get escape bytes.
if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then _LOG_C=1; else _LOG_C=; fi
log() {
  _t=2; case "${LOG_LEVEL:-W}" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"               in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  if [ -n "$_LOG_C" ]; then
    case "$1" in
      I) _lc='\033[1;36mI\033[0m' ;;
      W) _lc='\033[1;33mW\033[0m' ;;
      E) _lc='\033[1;31mE\033[0m' ;;
    esac
    printf '\033[90m%s\033[0m %b \033[32m%-16s\033[0m \033[35m%-14s\033[0m %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$_lc" "$2" "$3" "$4" >&2
  else
    printf '%s %s %-16s %-14s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
  fi
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
