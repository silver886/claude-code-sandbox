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
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
MACHINE_ARGS=""
[ -n "$MACHINE_CPUS" ]      && MACHINE_ARGS="$MACHINE_ARGS --cpus $MACHINE_CPUS"
[ -n "$MACHINE_MEMORY" ]    && MACHINE_ARGS="$MACHINE_ARGS --memory $MACHINE_MEMORY"
[ -n "$MACHINE_DISK_SIZE" ] && MACHINE_ARGS="$MACHINE_ARGS --disk-size $MACHINE_DISK_SIZE"
[ -n "$BASE_IMAGE" ]        && MACHINE_ARGS="$MACHINE_ARGS --image $BASE_IMAGE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ensure-credential.sh"

. "$SCRIPT_DIR/lib.sh"

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

# Prepare config dir with only the 3 required files
CONFIG_DIR="$CACHE_DIR/config"
mkdir -p "$CONFIG_DIR"
for f in .claude.json settings.json .credentials.json; do
  [ -f "$SCRIPT_DIR/$f" ] || { echo "Missing config file: $f" >&2; exit 1; }
  ln -f "$SCRIPT_DIR/$f" "$CONFIG_DIR/$f" 2>/dev/null || cp -f "$SCRIPT_DIR/$f" "$CONFIG_DIR/$f"
done

# Create runtime VM (fresh init — ignition runs, virtiofs mounts work natively)
podman machine init "$MACHINE_NAME" $MACHINE_ARGS \
  --volume "$PWD:/var/workdir" \
  --volume "$CONFIG_DIR:/var/config"
podman machine start "$MACHINE_NAME"

# Inject tool archives via SSH
for _archive in "$BASE_ARCHIVE" "$TOOL_ARCHIVE" "$CLAUDE_ARCHIVE"; do
  cat "$_archive" | podman machine ssh "$MACHINE_NAME" \
    'mkdir -p $HOME/.local/bin && tar -xzf - -C $HOME/.local/bin/ && chmod +x $HOME/.local/bin/*'
done

# Configure: symlink config files + make claude available system-wide
podman machine ssh "$MACHINE_NAME" -- "
  mkdir -p ~/.claude
  ln -sf /var/config/.claude.json ~/.claude.json
  ln -sf /var/config/settings.json ~/.claude/settings.json
  ln -sf /var/config/.credentials.json ~/.claude/.credentials.json
  sudo ln -sf \$HOME/.local/bin/claude-wrapper /usr/local/bin/claude
"

# Launch with TTY via raw ssh
SSH_PORT=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
SSH_KEY=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
ssh -t -p "$SSH_PORT" -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  core@localhost 'cd /var/workdir && exec $HOME/.local/bin/claude-wrapper --dangerously-skip-permissions'
