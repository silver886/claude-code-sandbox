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
"$PROJECT_ROOT/lib/ensure-credential.sh"

. "$PROJECT_ROOT/lib/init-config.sh"
. "$PROJECT_ROOT/lib/tools.sh"
init_config_dir

# ── Build tool archives ──

detect_arch
build_tool_archives

# ── Runtime VM ──

# Podman only supports one VM at a time — stop whatever is running
stop_all_machines() {
  for _m in $(podman machine list --format '{{.Name}}' --noheading 2>/dev/null | sed 's/\*$//' || true); do
    podman machine stop "$_m" 2>/dev/null || true
  done
}

WORKDIR_HASH=$(sha256 "$PWD" | cut -c1-16)
MACHINE_NAME="claude-$WORKDIR_HASH"
trap '
  podman machine stop "$MACHINE_NAME" 2>/dev/null || true
  podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
' EXIT

# Clean up leftovers from a previous interrupted run
podman machine stop "$MACHINE_NAME" 2>/dev/null || true
podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
stop_all_machines

# Create runtime VM (fresh init — ignition runs, virtiofs mounts work natively)
podman machine init "$MACHINE_NAME" $MACHINE_ARGS \
  --volume "$PWD:/var/workdir"
podman machine start "$MACHINE_NAME"

# Inject tool archives via SSH
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$CLAUDE_ARCHIVE"; do
  cat "$_archive" | podman machine ssh "$MACHINE_NAME" \
    'mkdir -p $HOME/.local/bin && tar -xJf - -C $HOME/.local/bin/ && chmod +x $HOME/.local/bin/*'
done

# Rename: claude → claude-bin, claude-wrapper → claude
podman machine ssh "$MACHINE_NAME" \
  'mv $HOME/.local/bin/claude $HOME/.local/bin/claude-bin && mv $HOME/.local/bin/claude-wrapper $HOME/.local/bin/claude'

# Launch with TTY via raw ssh
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
_ENV="CLAUDE_CONFIG_DIR=/var/workdir/.claude"
[ -n "$WITH_DNF" ] && _ENV="$_ENV CLAUDE_ENABLE_DNF=1"
ssh -t -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost "cd /var/workdir && exec env $_ENV \$HOME/.local/bin/claude --dangerously-skip-permissions"
