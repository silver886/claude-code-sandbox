#!/usr/bin/env sh
# bootstrap-agent-user.sh — strip 'core' of sudo/wheel group
# membership so the LLM agent (which runs AS core for /var/workdir uid
# parity) cannot escalate. All sudo-requiring bootstrap steps in
# script/podman-machine.sh run BEFORE this script; the agent launch
# SSH session opens AFTER, so PAM reads the updated /etc/group at
# login and the agent's session never has sudo group membership.
#
# Why core, not a separate uid 24368: virtiofs (macOS Podman) does
# not currently support idmapped mounts (mount_setattr returns
# EINVAL) and plain chown across host-user boundaries EPERMs. Every
# alternative — chmod 0777, setfacl, etc. — propagates to the host
# filesystem (the user's project directory on macOS), which is
# unacceptable. The only practical way for an in-VM user to read/
# write /var/workdir is to share the uid that virtiofs maps the host
# user to (1000 = core). So 'core' is reused as the agent identity,
# with sudo capability surgically removed.
#
# Why this is safe: FCOS destroys the VM on launcher exit; /etc/group
# changes are ephemeral. Each launch starts with stock /etc/group
# (core in sudo) and re-applies the strip before the agent session.
#
# Why the agent-wrapper purge contract still holds: agent-wrapper.sh
# guards `sudo enable-dnf --purge` behind `if [ -x .../enable-dnf ]`.
# The FCOS backend doesn't install enable-dnf, so the wrapper never
# invokes sudo — and after this script runs, no sudo is available
# anyway, regardless.
set -eu
. /usr/local/lib/crate/log.sh

for _g in sudo wheel; do
  if id -nG core | tr ' ' '\n' | grep -qx "$_g"; then
    log I bootstrap drop-group "removing core from $_g"
    gpasswd -d core "$_g" >/dev/null
  else
    log I bootstrap drop-group-skip "core not in $_g"
  fi
done
