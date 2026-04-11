#!/bin/sh
# enable-dnf.sh — grant the claude user passwordless sudo dnf.
# Runs inside the sandbox as root; called by claude-wrapper.sh.
if [ "$(id -u)" -eq 0 ]; then
  printf 'claude ALL=(root) NOPASSWD: /usr/bin/dnf\n' > /etc/sudoers.d/claude-dnf
  chmod 0440 /etc/sudoers.d/claude-dnf
  echo "DNF access enabled for claude"
else
  echo "Run as: sudo /usr/local/lib/claude-code-sandbox/enable-dnf" >&2
  exit 1
fi
