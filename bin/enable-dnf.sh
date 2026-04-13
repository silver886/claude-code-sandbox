#!/bin/sh
# enable-dnf.sh — grant the claude user passwordless sudo dnf.
# Runs inside the sandbox as root; called by claude-wrapper.sh.
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "error: must be run as root" >&2
  exit 1
fi

ENABLE=""
PURGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)   ENABLE=1; shift ;;
    --purge) PURGE=1; shift ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$ENABLE" ]; then
  printf 'claude ALL=(root) NOPASSWD: /usr/bin/dnf\n' > /etc/sudoers.d/claude-dnf
  chmod 0440 /etc/sudoers.d/claude-dnf
  echo "DNF access enabled for claude"
fi

if [ -n "$PURGE" ]; then
  # Remove the bootstrap sudoers rule so the agent cannot invoke this script later
  rm -f /etc/sudoers.d/claude-enable-dnf
fi
