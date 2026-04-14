#!/bin/sh
# init-launcher.sh — shared launcher initialization.
# Sourced (not executed). Requires: PROJECT_ROOT
#
# Sources init-config.sh and tools.sh, then provides init_launcher()
# which runs credential check, config init, arch detection, and
# tool archive build.
#
# Caller must set OPT_BASE_HASH, OPT_TOOL_HASH, OPT_CLAUDE_HASH,
# FORCE_PULL before calling init_launcher().
#
# Sets (via sourced libs): CONFIG_DIR, CONFIG_FILES, BASE_ARCHIVE,
# TOOL_ARCHIVE, CLAUDE_ARCHIVE, sha256(), detect_arch vars, etc.

# log.sh first so every downstream lib can use `log`. init-config.sh
# emits a gitignore warning that needs the logger available.
. "$PROJECT_ROOT/lib/log.sh"
. "$PROJECT_ROOT/lib/init-config.sh"
. "$PROJECT_ROOT/lib/tools.sh"

init_launcher() {
  log I launcher start "claude-code-sandbox $0"
  "$PROJECT_ROOT/lib/ensure-credential.sh"
  init_config_dir
  detect_arch
  build_tool_archives
}
