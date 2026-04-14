#!/bin/sh
# enable-dnf.sh — grant the claude user passwordless sudo dnf.
# Runs inside the sandbox as root; called by claude-wrapper.sh.
set -eu

# Inline structured logger — same format as lib/log.sh.
log() {
  printf '%s %s %-16s %-14s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$4" >&2
}

if [ "$(id -u)" -ne 0 ]; then
  log E dnf fail "must be run as root"
  exit 1
fi

ENABLE=""
PURGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)   ENABLE=1; shift ;;
    --purge) PURGE=1; shift ;;
    *) log E dnf arg-parse "unknown option: $1"; exit 1 ;;
  esac
done

if [ -n "$ENABLE" ]; then
  printf 'claude ALL=(root) NOPASSWD: /usr/bin/dnf\n' > /etc/sudoers.d/claude-dnf
  chmod 0440 /etc/sudoers.d/claude-dnf
  log I dnf enabled "passwordless sudo dnf granted to claude"
fi

if [ -n "$PURGE" ]; then
  # Remove the bootstrap sudoers rule so the agent cannot invoke this script later
  rm -f /etc/sudoers.d/claude-enable-dnf
  log I dnf purged "bootstrap sudoers rule removed"
fi
