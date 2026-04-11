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

LAUNCH=""
if [ "${1:-}" = "--exec" ]; then
  LAUNCH=1; shift
fi

BIN_DIR="${CLAUDE_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
for archive in "$@"; do
  tar -xJf "$archive" -C "$BIN_DIR/"
done
chmod +x "$BIN_DIR"/*
mv "$BIN_DIR/claude" "$BIN_DIR/claude-bin"
mv "$BIN_DIR/claude-wrapper" "$BIN_DIR/claude"

if [ -n "$LAUNCH" ]; then
  exec "$BIN_DIR/claude" --dangerously-skip-permissions
fi
