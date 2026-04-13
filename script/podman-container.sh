#!/bin/sh
set -eu

OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_CLAUDE_HASH=""
FORCE_PULL=""
BASE_IMAGE="fedora:latest"
WITH_DNF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --claude-hash) OPT_CLAUDE_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    --with-dnf)    WITH_DNF=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SELINUX_OPT=""
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
  SELINUX_OPT="--security-opt label=disable"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

. "$PROJECT_ROOT/lib/init-launcher.sh"
init_launcher

# ── Build base image ──

IMAGE_TAG="claude-base-$(sha256 "$(cat "$PROJECT_ROOT/Containerfile" "$PROJECT_ROOT/bin/enable-dnf.sh" "$PROJECT_ROOT/bin/setup-tools.sh" "$PROJECT_ROOT/config/sudoers-claude-enable-dnf")-$BASE_IMAGE")"
if ! podman image exists "$IMAGE_TAG" 2>/dev/null || [ -n "${FORCE_PULL:-}" ]; then
  _BUILD_ARGS=""
  [ -n "${FORCE_PULL:-}" ] && _BUILD_ARGS="--no-cache"
  podman image build $_BUILD_ARGS $SELINUX_OPT --build-arg "BASE_IMAGE=$BASE_IMAGE" --tag "$IMAGE_TAG" "$PROJECT_ROOT"
fi

# ── Run ──
#
# System config assembly via podman -v stacking (no in-container privileges):
#   1. cr/ as the base of /etc/claude-code-sandbox (rw, persists per project)
#   2. rw/<f> per-file mounts shadow cr at <f> with the host hardlinks
#      (mount-point gives EBUSY → in-place writeFileSync → host sync)
#   3. ro/<x>:ro per-file/per-subdir mounts shadow cr at <x>, read-only
#   4. .mask/ bind-mounted (read-only) over /var/workdir/.claude/.system
#      to mask system scope from project scope. Bind-of-empty-dir
#      instead of --tmpfs because podman --tmpfs nested under another
#      -v has been observed to silently no-op.

# Build the cfg-mount args as positional parameters so paths with
# spaces survive (POSIX sh has no real arrays — `set --` is the
# closest thing). Each `-v` flag is two positional args; `"$@"`
# expands them properly quoted into the podman run call.
set -- -v "$SYSTEM_DIR/cr:/etc/claude-code-sandbox"
for _f in $CONFIG_FILES; do
  set -- "$@" -v "$SYSTEM_DIR/rw/$_f:/etc/claude-code-sandbox/$_f"
done
for _f in $RO_FILES; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_f:/etc/claude-code-sandbox/$_f:ro"
done
for _d in $RO_DIRS; do
  set -- "$@" -v "$SYSTEM_DIR/ro/$_d:/etc/claude-code-sandbox/$_d:ro"
done

podman container run --interactive --tty --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  $SELINUX_OPT \
  -v "$BASE_ARCHIVE:/tmp/base.tar.xz:ro" \
  -v "$TOOL_ARCHIVE:/tmp/tool.tar.xz:ro" \
  -v "$CLAUDE_ARCHIVE:/tmp/claude.tar.xz:ro" \
  -v "$PWD:/var/workdir" \
  "$@" \
  -v "$SYSTEM_DIR/.mask:/var/workdir/.claude/.system:ro" \
  --workdir /var/workdir \
  --env CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox \
  ${WITH_DNF:+--env CLAUDE_ENABLE_DNF=1} \
  "$IMAGE_TAG"
