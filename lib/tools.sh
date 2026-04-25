#!/bin/sh
# tools.sh — tool archive build system (multi-agent).
# Sourced (not executed). Requires: PROJECT_ROOT, AGENT, AGENT_MANIFEST.

# sha256_file strips CR before hashing so a CRLF (Windows) checkout of
# the same commit produces the same hash as an LF (Linux) checkout —
# mirrors Tools.ps1's `Replace("`r`n", "`n")` for base-image hash parity.
if command -v sha256sum >/dev/null 2>&1; then
  sha256()      { printf '%s' "$1" | sha256sum                | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | sha256sum         | cut -d ' ' -f 1; }
else
  sha256()      { printf '%s' "$1" | shasum -a 256            | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | shasum -a 256     | cut -d ' ' -f 1; }
fi

# md5: 128-bit hash for short identifiers (per-workdir machine names).
# Identifier use, not crypto — adversarial collision construction does not
# apply here. macOS ships `md5` (BSD), Linux ships `md5sum` (coreutils);
# `openssl md5 -r` is the universal fallback. All three emit 32 hex chars.
# `command` prefix on the macOS branch bypasses function lookup so the
# function body's `md5` resolves to /sbin/md5, not to this function itself
# (the shell function and the binary share the name on BSD — without
# `command`, the call recurses, opens a pipe per frame, and crashes with
# `too many open files`).
if command -v md5sum >/dev/null 2>&1; then
  md5() { printf '%s' "$1" | md5sum                | cut -d ' ' -f 1; }
elif command -v md5 >/dev/null 2>&1; then
  md5() { printf '%s' "$1" | command md5 -q;                          }
else
  md5() { printf '%s' "$1" | openssl md5 -r        | cut -d ' ' -f 1; }
fi

# Wait for all PIDs; report and exit if any failed.
wait_all() {
  _wa_fail=0
  for _wa_pid in "$@"; do
    wait "$_wa_pid" || _wa_fail=1
  done
  if [ "$_wa_fail" -ne 0 ]; then
    echo "One or more background tasks failed" >&2; exit 1
  fi
}

# ── Tool archive system ──

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-sandbox"
TOOLS_DIR="$CACHE_DIR/tools"

# Distinct values grouped by the arch-suffix convention each tool uses.
# Only genuine primitives are case-branched; everything else is derived:
#   ARCH         — Node.js / pnpm suffix / npm platform sub-pkg {arch}
#                    (x64 on amd64, arm64 on arm64)
#   ARCH_GNU     — prefix of Rust-style triples
#                    (x86_64 on amd64, aarch64 on arm64)
#   ARCH_MICRO   — micro's release-asset suffix — unrelated schemes
#                    (linux64-static on amd64, linux-arm64 on arm64)
#   ARCH_RG      — ripgrep's triple — musl on amd64, gnu on arm64
#                    (BurntSushi/ripgrep doesn't ship musl arm64)
#   ARCH_TRIPLE  — full musl triple, used by uv and Codex {triple}
detect_arch() {
  _uname=$(uname -m)
  case "$_uname" in
    x86_64|amd64)
      ARCH="x64"
      ARCH_GNU="x86_64"
      ARCH_MICRO="linux64-static"
      _rg_libc="musl"
      ;;
    arm64|aarch64)
      ARCH="arm64"
      ARCH_GNU="aarch64"
      ARCH_MICRO="linux-arm64"
      _rg_libc="gnu"
      ;;
    *) log E tools fail "unsupported architecture: $_uname"; exit 1 ;;
  esac
  ARCH_TRIPLE="${ARCH_GNU}-unknown-linux-musl"
  ARCH_RG="${ARCH_GNU}-unknown-linux-${_rg_libc}"
}

# Substitute {arch}, {triple}, {version} in a template string.
_subst() {
  printf '%s' "$1" | sed \
    -e "s|{arch}|$ARCH|g" \
    -e "s|{triple}|$ARCH_TRIPLE|g" \
    -e "s|{version}|$2|g"
}

# Fetch shared tool versions in parallel.
# Sets: NODE_VER, RG_VER, MICRO_VER, PNPM_VER, UV_VER
fetch_shared_versions() {
  _DIR=$(mktemp -d)
  (curl -fsSL https://nodejs.org/dist/index.json \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  (curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest \
    | jq -r .tag_name > "$_DIR/rg") &
  _PID2=$!
  (curl -fsSL https://api.github.com/repos/zyedidia/micro/releases/latest \
    | jq -r .tag_name | sed 's/^v//' > "$_DIR/micro") &
  _PID3=$!
  (curl -fsSL https://registry.npmjs.org/pnpm/latest \
    | jq -r .version > "$_DIR/pnpm") &
  _PID4=$!
  (curl -fsSL https://pypi.org/pypi/uv/json \
    | jq -r .info.version > "$_DIR/uv") &
  _PID5=$!
  wait_all "$_PID1" "$_PID2" "$_PID3" "$_PID4" "$_PID5"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  PNPM_VER=$(cat "$_DIR/pnpm")
  UV_VER=$(cat "$_DIR/uv")
  rm -rf "$_DIR"
  if [ -z "$NODE_VER" ] || [ -z "$RG_VER" ] || [ -z "$MICRO_VER" ] || \
     [ -z "$PNPM_VER" ] || [ -z "$UV_VER" ]; then
    log E tools fail "failed to fetch one or more tool versions"
    exit 1
  fi
}

# Fetch the agent's latest npm version. Sets: AGENT_VER
fetch_agent_version() {
  _pkg=$(agent_get .executable.versionPackage)
  AGENT_VER=$(curl -fsSL "https://registry.npmjs.org/$_pkg/latest" | jq -r .version)
  if [ -z "$AGENT_VER" ]; then
    log E tools fail "failed to fetch version for $_pkg"
    exit 1
  fi
}

# Resolve a hash prefix to a cached archive path.
resolve_archive() {
  _tier="$1"; _prefix="$2"
  _matches=""; _count=0
  for _f in "$TOOLS_DIR/${_tier}-${_prefix}"*.tar.xz; do
    [ -f "$_f" ] || continue
    _matches="$_f"
    _count=$((_count + 1))
  done
  if [ "$_count" -eq 0 ]; then
    log E "tools.$_tier" fail "no cached archive matching hash '$_prefix'"
    exit 1
  elif [ "$_count" -gt 1 ]; then
    log E "tools.$_tier" fail "ambiguous hash prefix '$_prefix' matches multiple archives"
    exit 1
  fi
  printf '%s' "$_matches"
}

# Verify a cached tier archive is intact (not zero-length, not truncated).
_archive_ok() {
  [ -f "$1" ] && [ -s "$1" ] && tar --xz -tf "$1" >/dev/null 2>&1
}

# Pick the best available xz pack strategy. Probed once, cached in
# _PACK_XZ_MODE. Order (fastest → safest):
#   1. `pipe`     — external `xz` on PATH: `tar -cf - … | xz -0 -T0`.
#                   Fastest, explicit level/thread tuning. Fedora ships
#                   xz by default (dnf/rpm dependency). macOS does not;
#                   users install via `brew install xz`.
#   2. `bsdtar`   — tar is libarchive bsdtar: use `--xz --options
#                   'xz:compression-level=0,xz:threads=0'`. No external
#                   binary needed. macOS bsdtar and Windows bsdtar
#                   support this; GNU tar does not have `--options`.
#   3. `fallback` — `tar --xz` with default level (6) and single thread.
#                   Works everywhere but ~10× slower to pack than the
#                   top two paths. Warned at detection time.
_detect_pack_xz_mode() {
  [ -n "${_PACK_XZ_MODE:-}" ] && return 0
  if command -v xz >/dev/null 2>&1; then
    _PACK_XZ_MODE=pipe
  elif tar --version 2>&1 | head -1 | grep -qi bsdtar; then
    _PACK_XZ_MODE=bsdtar
  else
    _PACK_XZ_MODE=fallback
    log W tools.pack fallback "no xz CLI and tar is not bsdtar; using \`tar --xz\` defaults (slower)"
  fi
}

# Pack files into an xz-compressed tar archive using the detected mode.
# Args: OUT_PATH DIR FILES...
_pack_xz() {
  _detect_pack_xz_mode
  _pxz_out="$1"; _pxz_dir="$2"; shift 2
  case "$_PACK_XZ_MODE" in
    pipe)
      tar -C "$_pxz_dir" -cf - "$@" | xz -0 -T0 -c > "$_pxz_out"
      ;;
    bsdtar)
      tar -C "$_pxz_dir" --xz --options 'xz:compression-level=0,xz:threads=0' -cf "$_pxz_out" "$@"
      ;;
    fallback)
      tar -C "$_pxz_dir" --xz -cf "$_pxz_out" "$@"
      ;;
  esac
}

# ── Per-tier builders ──

_build_base_tier() {
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    if ! _archive_ok "$BASE_ARCHIVE"; then
      log E tools.base fail "pinned archive is corrupt: $(basename "$BASE_ARCHIVE")"
      return 1
    fi
    log I tools.base cache-pin "$(basename "$BASE_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$BASE_ARCHIVE"; then
    log I tools.base cache-hit "$(basename "$BASE_ARCHIVE")"
    return 0
  fi
  if [ -f "$BASE_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.base rebuild "cached archive corrupt; rebuilding"
    rm -f "$BASE_ARCHIVE"
  fi
  log I tools.base downloading "node $NODE_VER, ripgrep $RG_VER, micro $MICRO_VER"
  _DIR=$(mktemp -d)

  (curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-linux-${ARCH}.tar.xz" \
    | tar -xJ --strip-components=2 -C "$_DIR" "node-v${NODE_VER}-linux-${ARCH}/bin/node") &
  _PID1=$!
  (curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RG}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR" "ripgrep-${RG_VER}-${ARCH_RG}/rg") &
  _PID2=$!
  (curl -fsSL "https://github.com/zyedidia/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR" "micro-${MICRO_VER}/micro") &
  _PID3=$!
  wait_all "$_PID1" "$_PID2" "$_PID3"

  chmod +x "$_DIR/node" "$_DIR/rg" "$_DIR/micro"
  log I tools.base packing "$(basename "$BASE_ARCHIVE")"
  _BASE_TMP="$BASE_ARCHIVE.partial.$$"
  _pack_xz "$_BASE_TMP" "$_DIR" node rg micro
  mv -f "$_BASE_TMP" "$BASE_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.base cached "$(basename "$BASE_ARCHIVE")"
}

_build_tool_tier() {
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    if ! _archive_ok "$TOOL_ARCHIVE"; then
      log E tools.tool fail "pinned archive is corrupt: $(basename "$TOOL_ARCHIVE")"
      return 1
    fi
    log I tools.tool cache-pin "$(basename "$TOOL_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$TOOL_ARCHIVE"; then
    log I tools.tool cache-hit "$(basename "$TOOL_ARCHIVE")"
    return 0
  fi
  if [ -f "$TOOL_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W tools.tool rebuild "cached archive corrupt; rebuilding"
    rm -f "$TOOL_ARCHIVE"
  fi
  log I tools.tool downloading "pnpm $PNPM_VER, uv $UV_VER"
  _DIR=$(mktemp -d)

  (curl -fsSL "https://github.com/pnpm/pnpm/releases/download/v${PNPM_VER}/pnpm-linux-${ARCH}" \
    -o "$_DIR/pnpm") &
  _PID1=$!
  (curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_TRIPLE}.tar.gz" \
    | tar -xz --strip-components=1 -C "$_DIR") &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"

  chmod +x "$_DIR/pnpm" "$_DIR/uv" "$_DIR/uvx"
  log I tools.tool packing "$(basename "$TOOL_ARCHIVE")"
  _TOOL_TMP="$TOOL_ARCHIVE.partial.$$"
  _pack_xz "$_TOOL_TMP" "$_DIR" pnpm uv uvx
  mv -f "$_TOOL_TMP" "$TOOL_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.tool cached "$(basename "$TOOL_ARCHIVE")"
}

# Generate the per-agent agent-manifest.sh that the wrapper sources at
# startup. Outputs to stdout. Contents are derived from manifest fields
# so any change to binary/flags/env invalidates the tier-3 cache via
# _agent_manifest_sh_contents being included in the tier hash.
#
# The env loop goes through jq line-by-line (not via word-splitting on
# agent_get_kv's space-joined output) so values that contain spaces
# survive intact. Values are wrapped in single quotes — manifest values
# never contain single quotes.
_agent_manifest_sh_contents() {
  _binary=$(agent_get .binary)
  _flags=$(agent_get_list .launch.flags)
  printf 'AGENT_BINARY=%s\n' "$_binary"
  printf "AGENT_LAUNCH_FLAGS='%s'\n" "$_flags"
  # Point the agent's config-dir env var at the system staging path.
  # Skipped for agents whose manifest.configDir.env is empty (Gemini) —
  # they read from the hard-coded default under $HOME, mounted there.
  if [ -n "${AGENT_SANDBOX_ENV:-}" ]; then
    printf "export %s='%s'\n" "$AGENT_SANDBOX_ENV" "$AGENT_SANDBOX_DIR"
  fi
  jq -r '.launch.env // {} | to_entries[] | "export \(.key)='\''\(.value)'\''"' "$AGENT_MANIFEST"
}

_build_agent_tier() {
  if [ -n "${OPT_AGENT_HASH:-}" ]; then
    if ! _archive_ok "$AGENT_ARCHIVE"; then
      log E "tools.$AGENT" fail "pinned archive is corrupt: $(basename "$AGENT_ARCHIVE")"
      return 1
    fi
    log I "tools.$AGENT" cache-pin "$(basename "$AGENT_ARCHIVE")"
    return 0
  fi
  if [ -z "${FORCE_PULL:-}" ] && _archive_ok "$AGENT_ARCHIVE"; then
    log I "tools.$AGENT" cache-hit "$(basename "$AGENT_ARCHIVE")"
    return 0
  fi
  if [ -f "$AGENT_ARCHIVE" ] && [ -z "${FORCE_PULL:-}" ]; then
    log W "tools.$AGENT" rebuild "cached archive corrupt; rebuilding"
    rm -f "$AGENT_ARCHIVE"
  fi

  _type=$(agent_get .executable.type)
  _tarball=$(_subst "$(agent_get .executable.tarballUrl)" "$AGENT_VER")
  log I "tools.$AGENT" downloading "$AGENT $AGENT_VER ($_type)"

  _DIR=$(mktemp -d)
  _EXTRACT="$_DIR/extract"
  mkdir -p "$_EXTRACT"
  curl -fsSL "$_tarball" | tar -xz -C "$_EXTRACT"

  _binary=$(agent_get .binary)

  case "$_type" in
    platform-binary)
      _binPath=$(_subst "$(agent_get .executable.binPath)" "$AGENT_VER")
      _src="$_EXTRACT/$_binPath"
      if [ ! -f "$_src" ]; then
        log E "tools.$AGENT" fail "binary not found in tarball: $_binPath"
        exit 1
      fi
      cp "$_src" "$_DIR/${_binary}-bin"
      chmod +x "$_DIR/${_binary}-bin"
      ;;
    node-bundle)
      _entryPath=$(_subst "$(agent_get .executable.entryPath)" "$AGENT_VER")
      _pkg="${_binary}-pkg"
      # Relocate extract/ → <binary>-pkg/ for clarity and a stable
      # on-disk path (~/.local/lib/<binary>-pkg/) inside the sandbox.
      if [ -d "$_EXTRACT/package" ]; then
        mv "$_EXTRACT/package" "$_DIR/$_pkg"
      else
        log E "tools.$AGENT" fail "node bundle has no 'package/' dir"
        exit 1
      fi
      _entryRel=${_entryPath#package/}
      # Write a shim that node-execs the bundle entry.
      cat > "$_DIR/${_binary}-bin" <<SHIM
#!/usr/bin/env sh
exec node "\$HOME/.local/lib/$_pkg/$_entryRel" "\$@"
SHIM
      chmod +x "$_DIR/${_binary}-bin"
      ;;
    *)
      log E "tools.$AGENT" fail "unknown executable.type: $_type"
      exit 1
      ;;
  esac

  # Ship the wrapper under the agent's command name (regular file, not
  # a symlink) — keeps behavior identical across Linux/WSL/Windows
  # host filesystems where symlink creation quirks would otherwise
  # require an OS-specific fallback. Strip CR so Windows checkouts
  # (git autocrlf) pack a Linux-compatible #!/usr/bin/env sh shebang.
  tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh" > "$_DIR/$_binary"
  _agent_manifest_sh_contents > "$_DIR/agent-manifest.sh"
  chmod +x "$_DIR/$_binary"

  rm -rf "$_EXTRACT"

  log I "tools.$AGENT" packing "$(basename "$AGENT_ARCHIVE")"
  _AGENT_TMP="$AGENT_ARCHIVE.partial.$$"
  if [ "$_type" = "node-bundle" ]; then
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh "${_binary}-bin" "${_binary}-pkg"
  else
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh "${_binary}-bin"
  fi
  mv -f "$_AGENT_TMP" "$AGENT_ARCHIVE"
  rm -rf "$_DIR"
  log I "tools.$AGENT" cached "$(basename "$AGENT_ARCHIVE")"
}

# Build 3-tier tool archives. Respects OPT_BASE_HASH, OPT_TOOL_HASH,
# OPT_AGENT_HASH (pin to cached) and FORCE_PULL (skip cache).
# Sets: BASE_ARCHIVE, TOOL_ARCHIVE, AGENT_ARCHIVE
build_tool_archives() {
  mkdir -p "$TOOLS_DIR"
  rm -f "$TOOLS_DIR"/*.partial.* 2>/dev/null || true

  # Fetch versions once up front if any tier is unpinned. Shared tier
  # versions (node/rg/micro/pnpm/uv) and the agent version are
  # independent — fetch whichever subset we need.
  _need_shared=0
  _need_agent=0
  [ -z "${OPT_BASE_HASH:-}" ] && _need_shared=1
  [ -z "${OPT_TOOL_HASH:-}" ] && _need_shared=1
  [ -z "${OPT_AGENT_HASH:-}" ] && _need_agent=1
  if [ "$_need_shared" = 1 ] && [ -z "${NODE_VER:-}" ]; then
    fetch_shared_versions
  fi
  if [ "$_need_agent" = 1 ] && [ -z "${AGENT_VER:-}" ]; then
    fetch_agent_version
  fi

  # Archive path resolution.
  if [ -n "${OPT_BASE_HASH:-}" ]; then
    BASE_ARCHIVE=$(resolve_archive "base" "$OPT_BASE_HASH")
  else
    BASE_HASH=$(sha256 "base-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER")
    BASE_ARCHIVE="$TOOLS_DIR/base-$BASE_HASH.tar.xz"
  fi
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    TOOL_ARCHIVE=$(resolve_archive "tool" "$OPT_TOOL_HASH")
  else
    TOOL_HASH=$(sha256 "tool-pnpm:$PNPM_VER-uv:$UV_VER")
    TOOL_ARCHIVE="$TOOLS_DIR/tool-$TOOL_HASH.tar.xz"
  fi
  if [ -n "${OPT_AGENT_HASH:-}" ]; then
    AGENT_ARCHIVE=$(resolve_archive "$AGENT" "$OPT_AGENT_HASH")
  else
    # Include manifest source, generated agent-manifest.sh, and wrapper
    # source in the hash. Generated-sh catches changes to the generator
    # itself (e.g. adding the CLAUDE_CONFIG_DIR export). Strip CR so
    # Windows-side (CRLF) and Linux-side (LF) hashes match for the same
    # checkout.
    _manifest_src=$(tr -d '\r' < "$AGENT_MANIFEST")
    _manifest_sh=$(_agent_manifest_sh_contents)
    _wrapper_src=$(tr -d '\r' < "$PROJECT_ROOT/bin/agent-wrapper.sh")
    AGENT_HASH=$(sha256 "agent:$AGENT-ver:$AGENT_VER-arch:$ARCH-manifest:$_manifest_src-manifest-sh:$_manifest_sh-wrapper:$_wrapper_src")
    AGENT_ARCHIVE="$TOOLS_DIR/$AGENT-$AGENT_HASH.tar.xz"
  fi

  _build_base_tier &
  _BPID=$!
  _build_tool_tier &
  _TPID=$!
  _build_agent_tier &
  _APID=$!
  wait_all "$_BPID" "$_TPID" "$_APID"
}
