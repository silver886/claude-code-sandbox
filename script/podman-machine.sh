#!/bin/sh
set -eu

OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_CLAUDE_HASH=""
FORCE_PULL=""
BASE_IMAGE=""
MACHINE_CPUS=""
MACHINE_MEMORY=""
MACHINE_DISK_SIZE=""
WITH_DNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --claude-hash) OPT_CLAUDE_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    --cpus)        MACHINE_CPUS="$2"; shift 2 ;;
    --memory)      MACHINE_MEMORY="$2"; shift 2 ;;
    --disk-size)   MACHINE_DISK_SIZE="$2"; shift 2 ;;
    --with-dnf)    WITH_DNF=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
MACHINE_ARGS=""
[ -n "$MACHINE_CPUS" ]      && MACHINE_ARGS="$MACHINE_ARGS --cpus $MACHINE_CPUS"
[ -n "$MACHINE_MEMORY" ]    && MACHINE_ARGS="$MACHINE_ARGS --memory $MACHINE_MEMORY"
[ -n "$MACHINE_DISK_SIZE" ] && MACHINE_ARGS="$MACHINE_ARGS --disk-size $MACHINE_DISK_SIZE"
[ -n "$BASE_IMAGE" ]        && MACHINE_ARGS="$MACHINE_ARGS --image $BASE_IMAGE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Tear the VM down on any exit. The project's .claude/.system layout
# persists on the host — nothing to clean up there.
MACHINE_NAME=""
trap '
  [ -n "$MACHINE_NAME" ] && podman machine stop "$MACHINE_NAME" 2>/dev/null || true
  [ -n "$MACHINE_NAME" ] && podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
' EXIT

. "$PROJECT_ROOT/lib/init-launcher.sh"
init_launcher

# ── Runtime VM ──

# Podman only supports one VM at a time — stop whatever is running
stop_all_machines() {
  for _m in $(podman machine list --format '{{.Name}}' --noheading 2>/dev/null | sed 's/\*$//' || true); do
    podman machine stop "$_m" 2>/dev/null || true
  done
}

WORKDIR_HASH=$(sha256 "$PWD" | cut -c1-16)
MACHINE_NAME="claude-$WORKDIR_HASH"

# Clean up leftovers from a previous interrupted run
podman machine stop "$MACHINE_NAME" 2>/dev/null || true
podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
stop_all_machines

# Single host→guest mount: $PWD → /var/workdir. .claude/.system/rw/
# (containing hardlinks to the canonical config files) rides along
# inside the workdir, so the in-VM bind layer in setup-system-mounts.sh
# can reach them without exposing all of $CONFIG_DIR.
podman machine init "$MACHINE_NAME" $MACHINE_ARGS \
  --volume "$PWD:/var/workdir"
podman machine start "$MACHINE_NAME"

# Push setup-system-mounts.sh into the VM and run it as root. claude
# itself is launched below as the unprivileged `core` user — sudo is
# only used here to do the mount syscalls.
cat "$PROJECT_ROOT/bin/setup-system-mounts.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-system-mounts.sh && chmod +x /tmp/setup-system-mounts.sh'
podman machine ssh "$MACHINE_NAME" \
  "sudo /tmp/setup-system-mounts.sh \
     --workdir /var/workdir \
     --target /etc/claude-code-sandbox \
     --config-files '$CONFIG_FILES' \
     --ro-files '$RO_FILES' \
     --ro-dirs '$RO_DIRS'"

# Inject setup script and tool archives, then run setup
cat "$PROJECT_ROOT/bin/setup-tools.sh" | podman machine ssh "$MACHINE_NAME" \
  'cat > /tmp/setup-tools.sh && chmod +x /tmp/setup-tools.sh'
_ARCHIVE_ARGS=""
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$CLAUDE_ARCHIVE"; do
  _name=$(basename "$_archive")
  cat "$_archive" | podman machine ssh "$MACHINE_NAME" "cat > /tmp/$_name"
  _ARCHIVE_ARGS="$_ARCHIVE_ARGS /tmp/$_name"
done
podman machine ssh "$MACHINE_NAME" "/tmp/setup-tools.sh$_ARCHIVE_ARGS"

# ── Launch ──
#
# Raw `ssh -tt` to the VM — `podman machine ssh MACHINE "cmd"`'s pty
# allocation has been observed to be unreliable, leaving claude with
# no controlling tty. `-tt` forces pty allocation on the server side.
#
# Not `exec`'d — the EXIT trap still needs to fire to tear down the VM
# after claude exits.
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
_ENV="CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox"
[ -n "$WITH_DNF" ] && _ENV="$_ENV CLAUDE_ENABLE_DNF=1"
ssh -tt -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost \
  "cd /var/workdir && exec env $_ENV \$HOME/.local/bin/claude --dangerously-skip-permissions"
