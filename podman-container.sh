#!/bin/sh
set -eu

OPT_BASE_HASH=""
OPT_TOOL_HASH=""
OPT_CLAUDE_HASH=""
FORCE_PULL=""
BASE_IMAGE="fedora:latest"
while [ $# -gt 0 ]; do
  case "$1" in
    --base-hash)   OPT_BASE_HASH="$2"; shift 2 ;;
    --tool-hash)   OPT_TOOL_HASH="$2"; shift 2 ;;
    --claude-hash) OPT_CLAUDE_HASH="$2"; shift 2 ;;
    --force-pull)  FORCE_PULL=1; shift ;;
    --image)       BASE_IMAGE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ensure-credential.sh"

. "$SCRIPT_DIR/lib.sh"

# ── Build tool archives ──

detect_arch
build_tool_archives

# ── Build base image ──

IMAGE_TAG="claude-base-$(sha256 "$(cat "$SCRIPT_DIR/Containerfile")-$BASE_IMAGE")"
if ! podman image exists "$IMAGE_TAG" 2>/dev/null || [ -n "${FORCE_PULL:-}" ]; then
  _BUILD_ARGS=""
  [ -n "${FORCE_PULL:-}" ] && _BUILD_ARGS="--no-cache"
  podman image build $_BUILD_ARGS --security-opt label=disable --build-arg "BASE_IMAGE=$BASE_IMAGE" --tag "$IMAGE_TAG" "$SCRIPT_DIR"
fi

# ── Run ──

podman container run --interactive --tty --rm \
  --userns=keep-id:uid=1000,gid=1000 \
  --security-opt label=disable \
  -v "$BASE_ARCHIVE:/tmp/base.tar.gz:ro" \
  -v "$TOOL_ARCHIVE:/tmp/tool.tar.gz:ro" \
  -v "$CLAUDE_ARCHIVE:/tmp/claude.tar.gz:ro" \
  -v "$SCRIPT_DIR/.claude.json:/home/claude/.claude.json" \
  -v "$SCRIPT_DIR/settings.json:/home/claude/.claude/settings.json" \
  -v "$SCRIPT_DIR/.credentials.json:/home/claude/.claude/.credentials.json" \
  -v "$PWD:/var/workdir" \
  --workdir /var/workdir \
  "$IMAGE_TAG"
