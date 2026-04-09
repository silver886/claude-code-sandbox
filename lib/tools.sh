#!/bin/sh
# tools.sh — tool archive build system
# Sourced (not executed). Requires: PROJECT_ROOT

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { printf '%s' "$1" | sha256sum | cut -d ' ' -f 1; }
else
  sha256() { printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1; }
fi

# ── Tool archive system ──

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-sandbox"
TOOLS_DIR="$CACHE_DIR/tools"

detect_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)
      ARCH_NODE="x64"
      ARCH_RG="x86_64-unknown-linux-musl"
      ARCH_MICRO="linux64-static"
      ARCH_UV="x86_64-unknown-linux-musl"
      ARCH_PNPM="linux-x64"
      ARCH_CLAUDE="linux-x64"
      ;;
    arm64|aarch64)
      ARCH_NODE="arm64"
      ARCH_RG="aarch64-unknown-linux-gnu"
      ARCH_MICRO="linux-arm64"
      ARCH_UV="aarch64-unknown-linux-musl"
      ARCH_PNPM="linux-arm64"
      ARCH_CLAUDE="linux-arm64"
      ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
  esac
}

# Fetch all tool versions in parallel (6 concurrent curls)
# Sets: NODE_VER, RG_VER, MICRO_VER, PNPM_VER, UV_VER, CLAUDE_VER
fetch_tool_versions() {
  _DIR=$(mktemp -d)
  (curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  (curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest 2>/dev/null \
    | jq -r .tag_name > "$_DIR/rg") &
  _PID2=$!
  (curl -fsSL https://api.github.com/repos/zyedidia/micro/releases/latest 2>/dev/null \
    | jq -r .tag_name | sed 's/^v//' > "$_DIR/micro") &
  _PID3=$!
  (curl -fsSL https://registry.npmjs.org/pnpm/latest 2>/dev/null \
    | jq -r .version > "$_DIR/pnpm") &
  _PID4=$!
  (curl -fsSL https://pypi.org/pypi/uv/json 2>/dev/null \
    | jq -r .info.version > "$_DIR/uv") &
  _PID5=$!
  (curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null \
    | jq -r .version > "$_DIR/claude") &
  _PID6=$!
  wait "$_PID1" "$_PID2" "$_PID3" "$_PID4" "$_PID5" "$_PID6"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  PNPM_VER=$(cat "$_DIR/pnpm")
  UV_VER=$(cat "$_DIR/uv")
  CLAUDE_VER=$(cat "$_DIR/claude")
  rm -rf "$_DIR"
}

# Resolve a hash prefix to a cached archive path
# Usage: resolve_archive <tier> <hash_prefix>
resolve_archive() {
  _tier="$1"
  _prefix="$2"
  _matches=""
  _count=0
  for _f in "$TOOLS_DIR/${_tier}-${_prefix}"*.tar.xz; do
    [ -f "$_f" ] || continue
    _matches="$_f"
    _count=$((_count + 1))
  done
  if [ "$_count" -eq 0 ]; then
    echo "No cached archive found for $_tier hash '$_prefix'" >&2; exit 1
  elif [ "$_count" -gt 1 ]; then
    echo "Ambiguous hash prefix '$_prefix' — matches multiple $_tier archives" >&2; exit 1
  fi
  printf '%s' "$_matches"
}

# Build 3-tier tool archives. Respects OPT_BASE_HASH, OPT_TOOL_HASH,
# OPT_CLAUDE_HASH (pin to cached) and FORCE_PULL (skip cache).
# Sets: BASE_ARCHIVE, TOOL_ARCHIVE, CLAUDE_ARCHIVE
build_tool_archives() {
  mkdir -p "$TOOLS_DIR"

  # ── Tier 1: Base (node + rg + micro + claude-wrapper) ──
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    BASE_ARCHIVE=$(resolve_archive "base" "$OPT_BASE_HASH")
  else
    [ -z "${NODE_VER:-}" ] && fetch_tool_versions
    BASE_HASH=$(sha256 "base-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER-$(cat "$PROJECT_ROOT/bin/claude-wrapper.sh")")
    BASE_ARCHIVE="$TOOLS_DIR/base-$BASE_HASH.tar.xz"
    if [ ! -f "$BASE_ARCHIVE" ] || [ -n "${FORCE_PULL:-}" ]; then
      echo "  Downloading node $NODE_VER, ripgrep $RG_VER, micro $MICRO_VER..." >&2
      _DIR=$(mktemp -d)

      (curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${ARCH_NODE}.tar.xz" \
        | tar -xJ --strip-components=2 -C "$_DIR" "node-v${NODE_VER}-linux-${ARCH_NODE}/bin/node") &
      _PID1=$!
      (curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RG}.tar.gz" \
        | tar -xz --strip-components=1 -C "$_DIR" "ripgrep-${RG_VER}-${ARCH_RG}/rg") &
      _PID2=$!
      (curl -fsSL "https://github.com/zyedidia/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz" \
        | tar -xz --strip-components=1 -C "$_DIR" "micro-${MICRO_VER}/micro") &
      _PID3=$!
      wait "$_PID1" "$_PID2" "$_PID3"

      cp "$PROJECT_ROOT/bin/claude-wrapper.sh" "$_DIR/claude-wrapper"
      chmod +x "$_DIR/node" "$_DIR/rg" "$_DIR/micro" "$_DIR/claude-wrapper"
      tar -C "$_DIR" -cJf "$BASE_ARCHIVE" node rg micro claude-wrapper
      rm -rf "$_DIR"
    fi
  fi
  echo "base:   $(basename "$BASE_ARCHIVE" .tar.xz | sed 's/^base-//')" >&2

  # ── Tier 2: Tool (pnpm + uv + uvx) ──
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    TOOL_ARCHIVE=$(resolve_archive "tool" "$OPT_TOOL_HASH")
  else
    [ -z "${PNPM_VER:-}" ] && fetch_tool_versions
    TOOL_HASH=$(sha256 "tool-pnpm:$PNPM_VER-uv:$UV_VER")
    TOOL_ARCHIVE="$TOOLS_DIR/tool-$TOOL_HASH.tar.xz"
    if [ ! -f "$TOOL_ARCHIVE" ] || [ -n "${FORCE_PULL:-}" ]; then
      echo "  Downloading pnpm $PNPM_VER, uv $UV_VER..." >&2
      _DIR=$(mktemp -d)

      (curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VER}/pnpm-${ARCH_PNPM}" \
        -o "$_DIR/pnpm") &
      _PID1=$!
      (curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_UV}.tar.gz" \
        | tar -xz --strip-components=1 -C "$_DIR") &
      _PID2=$!
      wait "$_PID1" "$_PID2"

      chmod +x "$_DIR/pnpm" "$_DIR/uv" "$_DIR/uvx"
      tar -C "$_DIR" -cJf "$TOOL_ARCHIVE" pnpm uv uvx
      rm -rf "$_DIR"
    fi
  fi
  echo "tools:  $(basename "$TOOL_ARCHIVE" .tar.xz | sed 's/^tool-//')" >&2

  # ── Tier 3: Claude Code ──
  if [ -n "${OPT_CLAUDE_HASH:-}" ]; then
    CLAUDE_ARCHIVE=$(resolve_archive "claude" "$OPT_CLAUDE_HASH")
  else
    [ -z "${CLAUDE_VER:-}" ] && fetch_tool_versions
    CLAUDE_HASH=$(sha256 "claude-$CLAUDE_VER")
    CLAUDE_ARCHIVE="$TOOLS_DIR/claude-$CLAUDE_HASH.tar.xz"
    if [ ! -f "$CLAUDE_ARCHIVE" ] || [ -n "${FORCE_PULL:-}" ]; then
      echo "  Downloading claude $CLAUDE_VER..." >&2
      GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
      _DIR=$(mktemp -d)
      curl -fsSL "$GCS_BUCKET/$CLAUDE_VER/$ARCH_CLAUDE/claude" -o "$_DIR/claude"
      chmod +x "$_DIR/claude"
      tar -C "$_DIR" -cJf "$CLAUDE_ARCHIVE" claude
      rm -rf "$_DIR"
    fi
  fi
  echo "claude: $(basename "$CLAUDE_ARCHIVE" .tar.xz | sed 's/^claude-//')" >&2
}
