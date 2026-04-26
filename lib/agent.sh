#!/bin/sh
# agent.sh — manifest loader for multi-agent sandbox.
# Sourced (not executed). Requires: PROJECT_ROOT, AGENT (from launcher)
# Requires jq on the host (already required by ensure-credential).
#
# Sets after agent_load:
#   AGENT_DIR           — $PROJECT_ROOT/agent/$AGENT
#   AGENT_MANIFEST      — path to manifest.json
#   AGENT_BINARY        — e.g. "claude"
#   AGENT_PROJECT_DIR   — e.g. ".claude" (host staging dir base)
#   AGENT_CONFIG_DIR    — expanded host config dir path (respects env override)
#   CRATE_DIR           — in-sandbox config dir (mount target)
#   CRATE_ENV           — name of the env var the wrapper exports inside
#                         the sandbox to point the agent at CRATE_DIR
#                         (empty for agents without such an env var)
#
# Sandbox-side path policy:
#   - If the manifest declares configDir.env (Claude CLAUDE_CONFIG_DIR,
#     Codex CODEX_HOME, …) we stage config at a fixed system path
#     /usr/local/etc/crate/<agent> and set that env var in the
#     wrapper so the binary reads from there. Keeps /home/agent clean
#     and removes the podman-machine /home/agent→/home/core rewrite
#     for agents that honor the env.
#   - Otherwise we mount the staged config directly at the agent's
#     hard-coded default path (with $HOME=/home/agent).
#
# Helpers:
#   agent_get <jq-expr>          — single string value (empty if missing)
#   agent_get_list <jq-expr>     — space-joined array elements
#   agent_get_list_nul <jq-expr> — NUL-terminated array elements (read -d '')
#   agent_get_kv <jq-expr>       — space-joined K=V pairs from an object

agent_load() {
  AGENT_DIR="$PROJECT_ROOT/agent/$AGENT"
  AGENT_MANIFEST="$AGENT_DIR/manifest.json"
  if [ ! -f "$AGENT_MANIFEST" ]; then
    log E launcher fail "unknown agent: $AGENT (no $AGENT_MANIFEST)"
    exit 1
  fi

  AGENT_BINARY=$(agent_get .binary)
  AGENT_PROJECT_DIR=$(agent_get .projectDir)

  # Resolve the host-side config dir: respect the per-agent env override
  # if the manifest declares one AND it's set; else expand the default.
  _env_name=$(agent_get .configDir.env)
  _default=$(agent_get .configDir.default)
  AGENT_CONFIG_DIR=""
  if [ -n "$_env_name" ]; then
    eval "AGENT_CONFIG_DIR=\${$_env_name:-}"
  fi
  if [ -z "$AGENT_CONFIG_DIR" ]; then
    # Expand $HOME (and only $HOME) in default. Manifest authors can't
    # sneak arbitrary vars through — we hard-substitute a single token.
    case "$_default" in
      '$HOME'*) AGENT_CONFIG_DIR="$HOME${_default#\$HOME}" ;;
      *)        AGENT_CONFIG_DIR="$_default" ;;
    esac
  fi

  CRATE_ENV="$_env_name"
  if [ -n "$_env_name" ]; then
    CRATE_DIR="/usr/local/etc/crate/$AGENT"
  else
    case "$_default" in
      '$HOME'*) CRATE_DIR="/home/agent${_default#\$HOME}" ;;
      *)        CRATE_DIR="$_default" ;;
    esac
  fi
}

agent_get()      { jq -r "$1 // empty"            "$AGENT_MANIFEST"; }
agent_get_list() { jq -r "$1 // [] | join(\" \")" "$AGENT_MANIFEST"; }
agent_get_kv()   { jq -r "$1 // {} | to_entries | map(\"\(.key)=\(.value)\") | join(\" \")" "$AGENT_MANIFEST"; }

# NUL-delimited variant for callers that need to handle filenames with
# whitespace, quotes, or other shell metacharacters. Pipe into:
#   while IFS= read -r -d '' x; do …; done < <(agent_get_list_nul .files.rw)
# Each element is followed by a NUL byte; empty list emits nothing.
agent_get_list_nul() {
  jq -j "$1 // [] | map(. + \"\\u0000\") | add // \"\"" "$AGENT_MANIFEST"
}
