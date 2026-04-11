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

# Build config file mounts (live sync with host config dir)
_CFG_MOUNTS=""
for _f in $CONFIG_FILES; do
  _CFG_MOUNTS="$_CFG_MOUNTS -v $PWD/.claude/$_f:/var/workdir/.claude/$_f"
done

podman container run --interactive --tty --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  $SELINUX_OPT \
  -v "$BASE_ARCHIVE:/tmp/base.tar.xz:ro" \
  -v "$TOOL_ARCHIVE:/tmp/tool.tar.xz:ro" \
  -v "$CLAUDE_ARCHIVE:/tmp/claude.tar.xz:ro" \
  -v "$PWD:/var/workdir" \
  $_CFG_MOUNTS \
  --workdir /var/workdir \
  --env CLAUDE_CONFIG_DIR=/var/workdir/.claude \
  ${WITH_DNF:+--env CLAUDE_ENABLE_DNF=1} \
  "$IMAGE_TAG"
