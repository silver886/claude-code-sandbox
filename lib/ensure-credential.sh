#!/bin/sh
# ensure-credential.sh — multi-agent credential dispatcher.
#
# Sources lib/cred/<strategy>.sh based on the agent manifest's
# credential.strategy field, then invokes cred_check() to verify /
# refresh the auth file in place.
#
# Args: --agent NAME [--log-level I|W|E]
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
. "$PROJECT_ROOT/lib/log.sh"

AGENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E cred arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E cred arg-parse "unknown option: $1"; exit 1 ;;
  esac
done
: "${LOG_LEVEL:=W}"

if [ -z "$AGENT" ]; then
  log E cred arg-parse "--agent is required"
  exit 1
fi

. "$PROJECT_ROOT/lib/agent.sh"
agent_load

_strategy=$(agent_get .credential.strategy)
_strategy_sh="$PROJECT_ROOT/lib/cred/$_strategy.sh"
if [ ! -f "$_strategy_sh" ]; then
  log E cred fail "unknown credential strategy: $_strategy"
  exit 1
fi

# Pick the auth file — first entry in manifest's files.rw is by
# convention the credentials file for the refresh strategy to operate on.
_first_rw=$(jq -r '.files.rw[0] // empty' "$AGENT_MANIFEST")
if [ -z "$_first_rw" ]; then
  log E cred fail "manifest has no files.rw entries"
  exit 1
fi
CRED_PATH="$AGENT_CONFIG_DIR/$_first_rw"
AGENT_OAUTH_JSON="$AGENT_DIR/oauth.json"

log I cred check "$CRED_PATH ($_strategy)"
if [ ! -f "$CRED_PATH" ]; then
  log E cred fail "credentials file not found: $CRED_PATH; run '$AGENT' to authenticate"
  exit 1
fi

. "$_strategy_sh"
cred_check
