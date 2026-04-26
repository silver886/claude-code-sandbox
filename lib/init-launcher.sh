#!/bin/bash
# init-launcher.sh — shared launcher initialization.
# Sourced (not executed) by a bash launcher. Requires: PROJECT_ROOT,
# AGENT (set by caller). bash is required because init-config.sh below
# uses bash arrays + read -d '' for NUL-safe iteration.
#
# Sources agent.sh, init-config.sh, tools.sh, then provides
# init_launcher() which runs credential check, config init, arch
# detection, and tool archive build.
#
# Caller must set OPT_BASE_HASH, OPT_TOOL_HASH, OPT_AGENT_HASH,
# FORCE_PULL, AGENT before calling init_launcher().

# pipefail so the background curl|tar pipelines in tools.sh fail loudly
# when the upstream curl exits non-zero (set -e alone only checks the
# tail of the pipeline). Sourced into the bash launcher's parent shell.
set -o pipefail

. "$PROJECT_ROOT/lib/log.sh"
. "$PROJECT_ROOT/lib/agent.sh"
. "$PROJECT_ROOT/lib/init-config.sh"
. "$PROJECT_ROOT/lib/tools.sh"

init_launcher() {
  agent_load
  log I launcher start "CRATE ($AGENT) $0"
  "$PROJECT_ROOT/lib/ensure-credential.sh" --agent "$AGENT" --log-level "${LOG_LEVEL:-W}"
  init_config_dir
  detect_arch
  build_tool_archives
}
