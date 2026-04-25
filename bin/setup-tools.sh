#!/usr/bin/env sh
# setup-tools.sh — extract tool archives into the agent's ~/.local/bin
# (and ~/.local/lib for node-bundle agents). Usage:
#   setup-tools.sh [--exec] [--log-level I|W|E] <archive.tar.xz>...
#
# Every archive is extracted into $BIN_DIR (default $HOME/.local/bin);
# then any `*-pkg/` directories (only present for node-bundle agents)
# are relocated to $LIB_DIR (default $HOME/.local/lib) so their JS
# entry is shebang-exec'd by the shim baked into the tier-3 archive.
#
# The tier-3 archive already ships the binary pre-named ($AGENT_BINARY
# is a symlink → agent-wrapper, plus $AGENT_BINARY-bin holds the real
# executable or node shim). No renaming happens at runtime.
#
# With --exec, execs the wrapper after setup.
# --log-level is forwarded to the wrapper under --exec.
set -eu

. /usr/local/lib/agent-sandbox/log.sh

LAUNCH=""
_ARCHIVES=""
_ARCHIVE_COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --exec) LAUNCH=1; shift ;;
    --log-level)
      case "${2:-}" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E archive arg-parse "invalid --log-level: ${2:-} (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) _ARCHIVES="$_ARCHIVES $1"; _ARCHIVE_COUNT=$((_ARCHIVE_COUNT + 1)); shift ;;
  esac
done
: "${LOG_LEVEL:=W}"

BIN_DIR="${AGENT_BIN_DIR:-$HOME/.local/bin}"
LIB_DIR="${AGENT_LIB_DIR:-$HOME/.local/lib}"
log I archive extract "$BIN_DIR ($_ARCHIVE_COUNT archives)"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Unquoted expansion intentional: $_ARCHIVES is a space-separated list
# of archive paths (all under the cache dir, no spaces in practice).
for archive in $_ARCHIVES; do
  tar --xz -xf "$archive" -C "$BIN_DIR/"
done

# Move any node-bundle package dirs out of BIN_DIR into LIB_DIR so
# their JS entries can be exec'd via the baked shim.
for _d in "$BIN_DIR"/*-pkg; do
  [ -d "$_d" ] || continue
  _name=$(basename "$_d")
  rm -rf "$LIB_DIR/$_name"
  mv "$_d" "$LIB_DIR/$_name"
done

# Source the baked-in agent-manifest.sh so we know the agent's command
# name for the chmod list (and the --exec launch below).
if [ ! -f "$BIN_DIR/agent-manifest.sh" ]; then
  log E archive fail "agent-manifest.sh not found in $BIN_DIR"; exit 1
fi
. "$BIN_DIR/agent-manifest.sh"
[ -n "${AGENT_BINARY:-}" ] || { log E archive fail "AGENT_BINARY not set by agent-manifest.sh"; exit 1; }

# Set the executable bit on the specific binaries we ship — not every
# file in BIN_DIR. agent-manifest.sh is sourced (not exec'd), so it
# should stay mode 0644. Pre-existing files under BIN_DIR are also
# left untouched.
#
# Defense-in-depth: lib/tools.sh / Tools.ps1 already chmod +x before
# packing and tar preserves mode bits on extract, so this loop is
# normally a no-op. Kept in case a future packer, caching layer, or
# host filesystem loses the bit in transit.
for _name in node rg micro pnpm uv uvx "$AGENT_BINARY" "${AGENT_BINARY}-bin"; do
  [ -f "$BIN_DIR/$_name" ] && chmod +x "$BIN_DIR/$_name"
done

log I archive done "$BIN_DIR"

if [ -n "$LAUNCH" ]; then
  [ -x "$BIN_DIR/$AGENT_BINARY" ] || { log E run fail "$AGENT_BINARY wrapper not executable at $BIN_DIR/$AGENT_BINARY"; exit 1; }
  log I run launch "$BIN_DIR/$AGENT_BINARY --log-level $LOG_LEVEL"
  exec "$BIN_DIR/$AGENT_BINARY" --log-level "$LOG_LEVEL"
fi
