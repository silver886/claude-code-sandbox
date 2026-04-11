#!/bin/sh
# init-config.sh — resolve config dir and prepare $PWD/.claude for mounting.
# Sourced (not executed).
#
# Sets: CONFIG_DIR, CONFIG_FILES (space-separated list of existing files)
# Hardlinks files into $PWD/.claude after resolving any symlink chains.
#
# Claude Code uses atomic file replacement (write temp + rename), which
# would break hardlinks by creating a new inode. All backends prevent
# this by making each config file a bind mount point — rename() and
# unlink() fail with EBUSY, forcing in-place writes that preserve the
# shared inode.
#
# Container backends: podman -v mounts each file individually.
# VM/WSL backends: launcher scripts run mount --bind inside the sandbox.

# Resolve a path through all symlinks to the final target.
# Portable: uses only readlink (one level) in a loop, no -f flag.
_SYMLOOP_MAX=$(getconf SYMLOOP_MAX 2>/dev/null) || _SYMLOOP_MAX=""
case "$_SYMLOOP_MAX" in ''|undefined|-1) _SYMLOOP_MAX=40 ;; esac

_realpath() {
  _p="$1" _n=0
  while [ -L "$_p" ]; do
    _n=$((_n + 1))
    if [ "$_n" -gt "$_SYMLOOP_MAX" ]; then
      echo "Symlink chain too deep: $1" >&2; return 1
    fi
    _d=$(cd -P "$(dirname "$_p")" && pwd)
    _p=$(readlink "$_p")
    case "$_p" in /*) ;; *) _p="$_d/$_p" ;; esac
  done
  _d=$(cd -P "$(dirname "$_p")" && pwd)
  printf '%s/%s' "$_d" "$(basename "$_p")"
}

init_config_dir() {
  CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  mkdir -p "$CONFIG_DIR" "$PWD/.claude"

  CONFIG_FILES=""
  for _f in .credentials.json settings.json .claude.json; do
    [ -f "$CONFIG_DIR/$_f" ] || continue
    CONFIG_FILES="$CONFIG_FILES $_f"
    _real=$(_realpath "$CONFIG_DIR/$_f")
    ln -f "$_real" "$PWD/.claude/$_f"
  done
}
