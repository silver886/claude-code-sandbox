#!/bin/sh
mkdir -p "$HOME/.claude/projects" /var/workdir/.claude/sessions
ln -sfn /var/workdir/.claude/sessions "$HOME/.claude/projects/-var-workdir"

export PATH="$HOME/.local/bin:$PATH"

[ -f "$HOME/.shrc" ] && . "$HOME/.shrc"
[ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

# Find the real claude binary, skipping this wrapper
CLAUDE_BIN=""
_SELF=$(realpath "$0")
IFS=:
for _dir in $PATH; do
  [ -x "$_dir/claude" ] || continue
  [ "$(realpath "$_dir/claude")" = "$_SELF" ] && continue
  CLAUDE_BIN="$_dir/claude"
  break
done
unset IFS
if [ -z "$CLAUDE_BIN" ]; then
  echo "error: claude binary not found in PATH" >&2
  exit 1
fi

export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export EDITOR=micro

exec "$CLAUDE_BIN" "$@"
