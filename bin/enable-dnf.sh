#!/usr/bin/env sh
# enable-dnf.sh — grant the named user passwordless sudo dnf.
# Runs inside the sandbox as root; called by agent-wrapper.sh via the
# bootstrap sudoers rule, or directly as root for one-off setup.
# Target user resolution (highest precedence first):
#   1. --user USER      explicit (works when invoked directly as root)
#   2. $SUDO_USER       inherited from sudo (the wrapper-driven path)
# Works for both the container/WSL backends (user 'agent') and the
# podman-machine backend (user 'core' — see bin/bootstrap-agent-user.sh
# for why core is reused there).
# LOG_LEVEL arrives via the `--log-level` arg (never env) because sudo
# env_check strips unknown env vars and widening env_keep would widen
# the bootstrap sudoers rule.
set -eu

. /usr/local/lib/agent-sandbox/log.sh

if [ "$(id -u)" -ne 0 ]; then
  log E dnf fail "must be run as root"
  exit 1
fi

ENABLE=""
PURGE=""
USER_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)       ENABLE=1; shift ;;
    --purge)     PURGE=1; shift ;;
    --user)      USER_OPT="$2"; shift 2 ;;
    --log-level)
      case "$2" in
        I|i) LOG_LEVEL=I ;;
        W|w) LOG_LEVEL=W ;;
        E|e) LOG_LEVEL=E ;;
        *) log E dnf arg-parse "invalid --log-level: $2 (want I, W, or E)"; exit 1 ;;
      esac
      shift 2
      ;;
    *) log E dnf arg-parse "unknown option: $1"; exit 1 ;;
  esac
done

TARGET_USER="${USER_OPT:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ]; then
  log E dnf fail "no target user (pass --user USER or invoke via sudo)"
  exit 1
fi

if [ -n "$ENABLE" ]; then
  printf '%s ALL=(root) NOPASSWD: /usr/bin/dnf\n' "$TARGET_USER" > "/etc/sudoers.d/${TARGET_USER}-dnf"
  chmod 0440 "/etc/sudoers.d/${TARGET_USER}-dnf"
  log I dnf enabled "passwordless sudo dnf granted to $TARGET_USER"
fi

if [ -n "$PURGE" ]; then
  # Remove the bootstrap sudoers rule so the agent cannot invoke this script later
  rm -f "/etc/sudoers.d/${TARGET_USER}-enable-dnf"
  log I dnf purged "bootstrap sudoers rule removed for $TARGET_USER"
fi
