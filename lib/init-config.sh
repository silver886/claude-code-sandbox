#!/bin/sh
# init-config.sh — resolve config dir and prepare $PWD/.claude for mounting.
# Sourced (not executed).
#
# Sets: CONFIG_DIR, CONFIG_FILES (space-separated list of existing files)
# Also copies files into $PWD/.claude as fallback for scripts that
# cannot do individual file mounts (podman-machine, wsl).

init_config_dir() {
  CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  mkdir -p "$CONFIG_DIR" "$PWD/.claude"

  CONFIG_FILES=""
  for _f in .credentials.json settings.json .claude.json; do
    [ -f "$CONFIG_DIR/$_f" ] || continue
    CONFIG_FILES="$CONFIG_FILES $_f"
    cp -fL "$CONFIG_DIR/$_f" "$PWD/.claude/$_f"
  done
}
