#!/bin/sh
# tools.sh — tool archive build system (multi-agent).
# Sourced (not executed). Requires: PROJECT_ROOT, AGENT, AGENT_MANIFEST.

# sha256_file strips CR before hashing so a CRLF (Windows) checkout of
# the same commit produces the same hash as an LF (Linux) checkout —
# mirrors Tools.ps1's `Replace("`r`n", "`n")` for base-image hash parity.
# sha256_bin / sha512_bin do raw byte hashing for downloaded artifacts
# (binaries contain bytes that look like CR+LF; CR-stripping would
# corrupt the digest).
if command -v sha256sum >/dev/null 2>&1; then
  sha256()      { printf '%s' "$1" | sha256sum                | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | sha256sum         | cut -d ' ' -f 1; }
  sha256_bin()  { sha256sum                < "$1"             | cut -d ' ' -f 1; }
  sha512_bin()  { sha512sum                < "$1"             | cut -d ' ' -f 1; }
else
  sha256()      { printf '%s' "$1" | shasum -a 256            | cut -d ' ' -f 1; }
  sha256_file() { tr -d '\r'       < "$1" | shasum -a 256     | cut -d ' ' -f 1; }
  sha256_bin()  { shasum -a 256            < "$1"             | cut -d ' ' -f 1; }
  sha512_bin()  { shasum -a 512            < "$1"             | cut -d ' ' -f 1; }
fi

# Portable base64 decode: GNU coreutils uses `-d`, BSD/macOS pre-Catalina
# only accepts `-D` (newer macOS accepts both). Probe once.
if printf 'YQ==' | base64 -d >/dev/null 2>&1; then
  _base64_decode() { base64 -d; }
else
  _base64_decode() { base64 -D; }
fi

# Verify a downloaded file matches an expected sha256 hex digest. Exits 1
# on mismatch / empty expected, so the caller subshell propagates failure
# through wait_all instead of letting an unverified artifact proceed to
# extraction.
_verify_sha256() {
  _vf=$1; _vexp=$2; _vlabel=$3
  if [ -z "$_vexp" ]; then
    log E tools.verify fail "$_vlabel: empty expected sha256"
    exit 1
  fi
  _vact=$(sha256_bin "$_vf")
  if [ "$_vact" != "$_vexp" ]; then
    log E tools.verify fail "$_vlabel sha256 mismatch (expected $_vexp, got $_vact)"
    exit 1
  fi
}

# Verify a downloaded file matches an npm dist.integrity SRI value
# (`sha512-<base64>`). Decodes base64 → hex once and compares against
# the file's hex digest. POSIX-only deps (base64, od); openssl/xxd not
# required.
_verify_npm_integrity() {
  _nf=$1; _ni=$2; _nlabel=$3
  case "$_ni" in
    sha512-*) _nb64=${_ni#sha512-} ;;
    *) log E tools.verify fail "$_nlabel: unsupported integrity algorithm: $_ni"; exit 1 ;;
  esac
  _nexp_hex=$(printf '%s' "$_nb64" | _base64_decode | od -An -vtx1 | tr -d ' \n')
  if [ -z "$_nexp_hex" ]; then
    log E tools.verify fail "$_nlabel: failed to decode integrity value '$_ni'"
    exit 1
  fi
  _nact_hex=$(sha512_bin "$_nf")
  if [ "$_nact_hex" != "$_nexp_hex" ]; then
    log E tools.verify fail "$_nlabel sha512 mismatch (expected $_nexp_hex, got $_nact_hex)"
    exit 1
  fi
}

# Render shims from bin/node-shim.sh.tmpl for every entry in
# PKG_DIR/package.json's `.bin` map. Validates bin names, writes one
# shim per entry into OUT_DIR (with +x), and prints the rendered
# filenames space-joined to stdout — caller captures via $(...) for
# pack inputs.
#
# CANON_IN/CANON_OUT route the shim for the bin entry named CANON_IN
# to filename CANON_OUT instead of the bin key. The agent tier passes
# ($binary, ${binary}-bin) so agent-wrapper.sh finds its entry; the
# tool tier passes ("","") since there's no wrapper layer.
#
# Args: OUT_DIR  PKG_DIR  PKG_NAME  CANON_IN  CANON_OUT  STAGE
_render_node_bin_shims() {
  _rb_out_dir=$1; _rb_pkg_dir=$2; _rb_pkg_name=$3
  _rb_canon_in=$4; _rb_canon_out=$5; _rb_stage=$6
  _rb_pkg_json="$_rb_pkg_dir/package.json"
  if [ ! -f "$_rb_pkg_json" ]; then
    log E "$_rb_stage" fail "package.json missing at $_rb_pkg_json"
    exit 1
  fi
  _rb_tmpl=$(tr -d '\r' < "$PROJECT_ROOT/bin/node-shim.sh.tmpl")
  _rb_files=""
  _rb_saw_canon=0
  while IFS= read -r -d '' _rb_name && IFS= read -r -d '' _rb_path; do
    # Validate bin key: rejects path separators, shell metas, leading
    # hyphen (would look like a flag), and leading dot (no `..`).
    case "$_rb_name" in
      ''|*[!A-Za-z0-9._-]*|-*|.*)
        log E "$_rb_stage" fail "invalid bin name in $_rb_pkg_json: '$_rb_name'"
        exit 1 ;;
    esac
    _rb_entry=${_rb_path#./}
    # Validate bin path: must be relative, no traversal, safe segments.
    # Interpolated into the shim's `exec node "$HOME/.local/lib/PKG/{{ENTRY}}"`
    # template — a quote, backslash, control char, newline, or '..' would
    # either break the double-quoted shell literal, escape the package
    # dir, or surface as an invalid filesystem write target. Mirrors the
    # existing per-segment whitelist used for .binary / .projectDir /
    # files.* entries elsewhere in the loader.
    case "$_rb_entry" in
      ''|/*)
        log E "$_rb_stage" fail "invalid bin path in $_rb_pkg_json: '$_rb_path' (must be a non-empty relative path)"
        exit 1
        ;;
    esac
    _rb_old_ifs=$IFS
    IFS=/
    for _rb_seg in $_rb_entry; do
      case "$_rb_seg" in
        ''|.|..|*[!A-Za-z0-9._-]*)
          IFS=$_rb_old_ifs
          log E "$_rb_stage" fail "invalid bin path segment in $_rb_pkg_json: '$_rb_path' (segment '$_rb_seg' must match [A-Za-z0-9._-]+ and not be '.' or '..')"
          exit 1
          ;;
      esac
    done
    IFS=$_rb_old_ifs
    if [ -n "$_rb_canon_in" ] && [ "$_rb_name" = "$_rb_canon_in" ]; then
      _rb_target=$_rb_canon_out
      _rb_saw_canon=1
    else
      _rb_target=$_rb_name
      # Reject aux-shim collisions with reserved agent-tier filenames.
      # Only relevant when a canonical mapping is in effect (tool tier
      # has no wrapper / manifest, so this check naturally skips).
      if [ -n "$_rb_canon_in" ]; then
        case "$_rb_target" in
          agent-manifest.sh|"$_rb_canon_in"|"$_rb_canon_out"|"${_rb_canon_in}-pkg")
            log E "$_rb_stage" fail "aux bin '$_rb_name' collides with reserved filename"
            exit 1 ;;
        esac
      fi
    fi
    _rb_shim=${_rb_tmpl//\{\{PKG\}\}/$_rb_pkg_name}
    _rb_shim=${_rb_shim//\{\{ENTRY\}\}/$_rb_entry}
    printf '%s' "$_rb_shim" > "$_rb_out_dir/$_rb_target"
    chmod +x "$_rb_out_dir/$_rb_target"
    _rb_files="$_rb_files $_rb_target"
  done < <(jq -j '
    if (.bin | type) == "object" then
      .bin | to_entries[] | "\(.key)\u0000\(.value)\u0000"
    else
      error("package.json: .bin must be an object, got \(.bin | type)")
    end
  ' "$_rb_pkg_json")
  if [ -z "$_rb_files" ]; then
    log E "$_rb_stage" fail "$_rb_pkg_json: no .bin entries rendered"
    exit 1
  fi
  if [ -n "$_rb_canon_in" ] && [ "$_rb_saw_canon" = 0 ]; then
    log E "$_rb_stage" fail "canonical bin '$_rb_canon_in' not found in $_rb_pkg_json"
    exit 1
  fi
  printf '%s' "${_rb_files# }"
}

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

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/crate"
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
  (curl -fsSL -A "$CRATE_USER_AGENT" https://nodejs.org/dist/index.json \
    | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//' > "$_DIR/node") &
  _PID1=$!
  # ripgrep: crates.io is the canonical registry (BurntSushi publishes
  # there in lock-step with GH releases). Hitting the API there avoids
  # GH's 60 req/hour unauthenticated rate limit.
  (curl -fsSL -A "$CRATE_USER_AGENT" https://crates.io/api/v1/crates/ripgrep \
    | jq -r .crate.max_stable_version > "$_DIR/rg") &
  _PID2=$!
  # micro is GH-only, so we resolve the version via the web-side
  # `releases/latest` redirect — github.com (not api.github.com) — which
  # is not subject to the API rate limit. The Location header points to
  # `releases/tag/v<version>`; strip the leading `v`.
  (_final=$(curl -fsSLI -A "$CRATE_USER_AGENT" -o /dev/null -w '%{url_effective}' \
     https://github.com/micro-editor/micro/releases/latest)
   _tag=${_final##*/}
   printf '%s' "${_tag#v}" > "$_DIR/micro") &
  _PID3=$!
  # pnpm: full `latest` metadata in one fetch — gets version, tarball
  # URL, and sha512 SRI in a single ~3 KB response. We use the vanilla
  # `pnpm` package (mjs node-bundle, ~17 MB unpacked) executed against
  # the node we already ship in the base tier, NOT the per-arch
  # @pnpm/linuxstatic-<arch> Node SEA (~140 MB unpacked, ~123 MB of
  # which is bundled node — wasted bytes for us).
  (curl -fsSL -A "$CRATE_USER_AGENT" https://registry.npmjs.org/pnpm/latest \
    > "$_DIR/pnpm.json") &
  _PID4=$!
  (curl -fsSL -A "$CRATE_USER_AGENT" https://pypi.org/pypi/uv/json \
    | jq -r .info.version > "$_DIR/uv") &
  _PID5=$!
  wait_all "$_PID1" "$_PID2" "$_PID3" "$_PID4" "$_PID5"
  NODE_VER=$(cat "$_DIR/node")
  RG_VER=$(cat "$_DIR/rg")
  MICRO_VER=$(cat "$_DIR/micro")
  _pnpm_meta=$(cat "$_DIR/pnpm.json")
  UV_VER=$(cat "$_DIR/uv")
  rm -rf "$_DIR"
  PNPM_VER=$(printf '%s' "$_pnpm_meta" | jq -r '.version // empty')
  PNPM_TARBALL_URL=$(printf '%s' "$_pnpm_meta" | jq -r '.dist.tarball // empty')
  PNPM_NPM_INTEGRITY=$(printf '%s' "$_pnpm_meta" | jq -r '.dist.integrity // empty')
  if [ -z "$NODE_VER" ] || [ -z "$RG_VER" ] || [ -z "$MICRO_VER" ] || \
     [ -z "$PNPM_VER" ] || [ -z "$UV_VER" ]; then
    log E tools fail "failed to fetch one or more tool versions"
    exit 1
  fi
  if [ -z "$PNPM_TARBALL_URL" ] || [ -z "$PNPM_NPM_INTEGRITY" ]; then
    log E tools fail "pnpm $PNPM_VER: missing dist.tarball / dist.integrity"
    exit 1
  fi
  # Pinning the URL host to registry.npmjs.org matches the agent-tier
  # policy: a compromised metadata redirect can't point us at an
  # attacker host.
  case "$PNPM_TARBALL_URL" in
    https://registry.npmjs.org/*) ;;
    *) log E tools fail "pnpm tarball URL not on registry.npmjs.org: $PNPM_TARBALL_URL"; exit 1 ;;
  esac
}

# Fetch the agent's latest npm version. Sets: AGENT_VER
fetch_agent_version() {
  _pkg=$(agent_get .executable.versionPackage)
  AGENT_VER=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://registry.npmjs.org/$_pkg/latest" | jq -r .version)
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

  # Each subshell: download to disk → fetch publisher checksum → verify
  # → extract. Verifying before extract is the whole point — a hostile
  # tarball could otherwise drop binaries the build then chmod +x'es.
  (
    _name="node-v${NODE_VER}-linux-${ARCH}.tar.xz"
    _file="$_DIR/_node.tar.xz"
    curl -fsSL -A "$CRATE_USER_AGENT" "https://nodejs.org/dist/v${NODE_VER}/$_name" -o "$_file"
    # Node ships one SHASUMS256.txt covering every platform tarball.
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "https://nodejs.org/dist/v${NODE_VER}/SHASUMS256.txt" \
      | awk -v n="$_name" '$2 == n {print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "node $_name"
    tar -xJ --strip-components=2 -C "$_DIR" -f "$_file" "node-v${NODE_VER}-linux-${ARCH}/bin/node"
    rm -f "$_file"
  ) &
  _PID1=$!
  (
    _url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VER}/ripgrep-${RG_VER}-${ARCH_RG}.tar.gz"
    _file="$_DIR/_rg.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha256" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "ripgrep"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file" "ripgrep-${RG_VER}-${ARCH_RG}/rg"
    rm -f "$_file"
  ) &
  _PID2=$!
  (
    _url="https://github.com/micro-editor/micro/releases/download/v${MICRO_VER}/micro-${MICRO_VER}-${ARCH_MICRO}.tar.gz"
    _file="$_DIR/_micro.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    # micro uses '.sha' (not '.sha256') as its sidecar suffix; the
    # contents are still the standard '<sha256>  <filename>' format.
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "micro"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file" "micro-${MICRO_VER}/micro"
    rm -f "$_file"
  ) &
  _PID3=$!
  wait_all "$_PID1" "$_PID2" "$_PID3"

  chmod +x "$_DIR/node" "$_DIR/rg" "$_DIR/micro"
  log I tools.base packing "$(basename "$BASE_ARCHIVE")"
  # mktemp (not "$$") so a stale predictable-named partial from a prior
  # run can't be picked up as ours. The .partial.* glob in
  # build_tool_archives still matches because mktemp appends to the
  # template suffix.
  _BASE_TMP=$(mktemp "$BASE_ARCHIVE.partial.XXXXXXXX")
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

  (
    # pnpm vanilla npm package: a Node bundle (mjs entries, ~17 MB
    # unpacked) executed against the base-tier node via the same shim
    # template the agent tier uses for node-bundle agents. Verified
    # against npm's sha512 `dist.integrity` — same trust path as the
    # agent tier.
    _file="$_DIR/_pnpm.tgz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$PNPM_TARBALL_URL" -o "$_file"
    _verify_npm_integrity "$_file" "$PNPM_NPM_INTEGRITY" "pnpm npm tarball"
    _extract="$_DIR/_pnpm_extract"
    mkdir -p "$_extract"
    tar -xz -C "$_extract" -f "$_file"
    rm -f "$_file"
    if [ ! -d "$_extract/package" ]; then
      log E tools.tool fail "pnpm npm tarball missing 'package/' dir"
      exit 1
    fi
    # Relocate package/ → pnpm-pkg/ matching the on-disk layout used
    # for node-bundle agents (~/.local/lib/<name>-pkg/) — setup-tools.sh
    # globs `*-pkg` and moves them into LIB_DIR generically. Shim
    # rendering happens after wait_all so the pnpm-pkg/package.json
    # is fully visible to _render_node_bin_shims.
    mv "$_extract/package" "$_DIR/pnpm-pkg"
    rm -rf "$_extract"
  ) &
  _PID1=$!
  (
    _url="https://github.com/astral-sh/uv/releases/download/${UV_VER}/uv-${ARCH_TRIPLE}.tar.gz"
    _file="$_DIR/_uv.tar.gz"
    curl -fsSL -A "$CRATE_USER_AGENT" "$_url" -o "$_file"
    _exp=$(curl -fsSL -A "$CRATE_USER_AGENT" "${_url}.sha256" | awk '{print $1; exit}')
    _verify_sha256 "$_file" "$_exp" "uv"
    tar -xz --strip-components=1 -C "$_DIR" -f "$_file"
    rm -f "$_file"
  ) &
  _PID2=$!
  wait_all "$_PID1" "$_PID2"

  # Render one shim per package.json `bin` entry. pnpm publishes 4
  # (pn, pnx, pnpm, pnpx — pn/pnpm and pnx/pnpx are aliases for the
  # same JS files); shipping them all keeps user-facing invocation
  # parity with `npm i -g pnpm`. Same template the agent tier renders
  # for node-bundle agents — single source of truth.
  _pnpm_shims=$(_render_node_bin_shims "$_DIR" "$_DIR/pnpm-pkg" pnpm-pkg "" "" tools.tool)

  # The rendered shims (`pnpm`, `pn`, `pnx`, `pnpx`) are sh scripts
  # invoked directly; the mjs entries inside pnpm-pkg/ are read by
  # node and don't need the exec bit. uv/uvx are native binaries.
  chmod +x "$_DIR/uv" "$_DIR/uvx"
  log I tools.tool packing "$(basename "$TOOL_ARCHIVE")"
  _TOOL_TMP=$(mktemp "$TOOL_ARCHIVE.partial.XXXXXXXX")
  # shellcheck disable=SC2086 -- $_pnpm_shims intentionally word-split;
  # _render_node_bin_shims validates names against [A-Za-z0-9._-].
  _pack_xz "$_TOOL_TMP" "$_DIR" $_pnpm_shims pnpm-pkg uv uvx
  mv -f "$_TOOL_TMP" "$TOOL_ARCHIVE"
  rm -rf "$_DIR"
  log I tools.tool cached "$(basename "$TOOL_ARCHIVE")"
}

# POSIX shell-quote a value: wrap in single quotes with each embedded
# `'` rewritten as `'\''`. The result round-trips through `. file` for
# any byte sequence — including newlines and quotes — so a manifest
# value can no longer corrupt the agent-manifest.sh sourced by the
# wrapper. Bash parameter expansion (${var//pat/repl}) is the only
# non-POSIX feature; this whole library is bash-only (see
# init-launcher.sh's `set -o pipefail` and bash-array note).
_sh_quote() {
  _q=${1//\'/\'\\\'\'}
  printf "'%s'" "$_q"
}

# Generate the per-agent agent-manifest.sh that the wrapper sources at
# startup. Outputs to stdout. Contents are derived from manifest fields
# so any change to binary/flags/env invalidates the tier-3 cache via
# _agent_manifest_sh_contents being included in the tier hash.
#
# Every value is POSIX single-quoted via _sh_quote so the file is safe
# to `. source` regardless of what's in the manifest. Env keys are
# validated against [A-Za-z_][A-Za-z0-9_]* before emission — a bad key
# would either invalidate sh syntax or shell-inject through the
# unquoted `export <key>=...` slot.
_agent_manifest_sh_contents() {
  _binary=$(agent_get .binary)
  printf 'AGENT_BINARY='; _sh_quote "$_binary"; printf '\n'
  # Emit launch.flags as a function body so each flag preserves its
  # argument boundary across the manifest → wrapper boundary. A flat
  # space-joined string would lose boundaries on any flag value
  # containing whitespace, an empty string, or shell metacharacters,
  # and the wrapper's word-splitting expansion would then misframe
  # subsequent args. The wrapper calls
  #   exec_agent_with_flags "$_bin" "$@"
  # to exec with flags-then-user-args.
  printf 'exec_agent_with_flags() {\n  _eaf_bin=$1\n  shift\n  exec "$_eaf_bin"'
  while IFS= read -r -d '' _flag; do
    printf ' '
    _sh_quote "$_flag"
  done < <(jq -j '.launch.flags // [] | map(. + "\u0000") | add // ""' "$AGENT_MANIFEST")
  printf ' "$@"\n}\n'
  # Point the agent's config-dir env var at the system staging path.
  # Skipped for agents whose manifest.configDir.env is empty (Gemini) —
  # they read from the hard-coded default under $HOME, mounted there.
  # CRATE_ENV is already shell-name-validated in agent_load.
  if [ -n "${CRATE_ENV:-}" ]; then
    printf 'export %s=' "$CRATE_ENV"; _sh_quote "$CRATE_DIR"; printf '\n'
  fi
  # Iterate launch.env via NUL-separated key,value,key,value out of jq
  # so newlines and embedded quotes survive the jq → shell handoff.
  while IFS= read -r -d '' _k && IFS= read -r -d '' _v; do
    case "$_k" in
      [A-Za-z_]*) ;;
      *) log E launcher fail "invalid launch.env key in $AGENT_MANIFEST: '$_k' (must match [A-Za-z_][A-Za-z0-9_]*)"; exit 1 ;;
    esac
    case "$_k" in
      *[!A-Za-z0-9_]*)
        log E launcher fail "invalid launch.env key in $AGENT_MANIFEST: '$_k' (must match [A-Za-z_][A-Za-z0-9_]*)"
        exit 1
        ;;
    esac
    printf 'export %s=' "$_k"; _sh_quote "$_v"; printf '\n'
  done < <(jq -j '.launch.env // {} | to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$AGENT_MANIFEST")
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

  # Resolve npm package name AND tarball-version from the URL. The
  # version we look up MUST match the tarball we download — codex
  # publishes per-platform binaries as version-suffixed releases
  # (`0.125.0-linux-x64`, `0.125.0-darwin-arm64`, …) under the same
  # `@openai/codex` package, so the integrity for `0.125.0` (the JS
  # wrapper) is NOT the integrity for `0.125.0-linux-x64` (the
  # platform binary we actually fetch). Extract the version from the
  # tarball's basename instead of using $AGENT_VER, which only knows
  # the wrapper's version. URL shape: `<scope>/<name>/-/<basename>-<version>.tgz`.
  # Restrict to registry.npmjs.org so a manifest can't redirect the
  # verification step at an attacker-controlled metadata host.
  case "$_tarball" in
    https://registry.npmjs.org/*)
      _rest=${_tarball#https://registry.npmjs.org/}
      _pkg=${_rest%%/-/*}
      _filename=${_rest##*/-/}
      _pkg_base=${_pkg##*/}
      case "$_filename" in
        "${_pkg_base}-"*.tgz)
          _tar_ver=${_filename#${_pkg_base}-}
          _tar_ver=${_tar_ver%.tgz}
          ;;
        *)
          log E "tools.$AGENT" fail "tarball filename does not match '<pkg>-<version>.tgz' shape: $_filename (pkg=$_pkg_base)"
          exit 1
          ;;
      esac
      ;;
    *)
      log E "tools.$AGENT" fail "unsupported tarball host (only registry.npmjs.org is allowed): $_tarball"
      exit 1
      ;;
  esac
  _meta_url="https://registry.npmjs.org/$_pkg/$_tar_ver"
  _integrity=$(curl -fsSL -A "$CRATE_USER_AGENT" "$_meta_url" | jq -r '.dist.integrity // empty')
  if [ -z "$_integrity" ]; then
    log E "tools.$AGENT" fail "no dist.integrity at $_meta_url"
    exit 1
  fi

  _DIR=$(mktemp -d)
  _EXTRACT="$_DIR/extract"
  _TARFILE="$_DIR/_agent.tgz"
  mkdir -p "$_EXTRACT"
  curl -fsSL -A "$CRATE_USER_AGENT" "$_tarball" -o "$_TARFILE"
  _verify_npm_integrity "$_TARFILE" "$_integrity" "$AGENT npm tarball"
  tar -xz -C "$_EXTRACT" -f "$_TARFILE"
  rm -f "$_TARFILE"

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
      _pkg="${_binary}-pkg"
      # Relocate extract/ → <binary>-pkg/ for clarity and a stable
      # on-disk path (~/.local/lib/<binary>-pkg/) inside the sandbox.
      if [ -d "$_EXTRACT/package" ]; then
        mv "$_EXTRACT/package" "$_DIR/$_pkg"
      else
        log E "tools.$AGENT" fail "node bundle has no 'package/' dir"
        exit 1
      fi
      # Render one shim per package.json `bin` entry. The canonical
      # entry (key matching .binary) goes to ${_binary}-bin so
      # agent-wrapper.sh finds it; auxiliary entries become standalone
      # shims under their bin keys. Captured _agent_shims is the full
      # space-joined list of rendered filenames (canonical + aux),
      # word-split into pack inputs below.
      _agent_shims=$(_render_node_bin_shims "$_DIR" "$_DIR/$_pkg" "$_pkg" \
        "$_binary" "${_binary}-bin" "tools.$AGENT")
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
  _AGENT_TMP=$(mktemp "$AGENT_ARCHIVE.partial.XXXXXXXX")
  if [ "$_type" = "node-bundle" ]; then
    # shellcheck disable=SC2086 -- $_agent_shims intentionally word-split;
    # _render_node_bin_shims validates names against [A-Za-z0-9._-].
    _pack_xz "$_AGENT_TMP" "$_DIR" "$_binary" agent-manifest.sh $_agent_shims "${_binary}-pkg"
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
  # Reap ORPHAN partials from prior builds that crashed. The cache dir
  # is shared across concurrent launchers — a blanket `rm -f *.partial.*`
  # would race-delete another active launcher's in-progress archive
  # (its `mv -f` would then fail). Each launch's partial is uniquely
  # named via mktemp; a successful build always consumes its own
  # partial via `mv -f`. Anything older than the threshold is by
  # definition abandoned, so age-gating cleanup never touches a live
  # builder's file. Both GNU find (Linux) and BSD find (macOS) support
  # -mmin and -delete.
  find "$TOOLS_DIR" -maxdepth 1 -name '*.partial.*' -mmin +60 -delete 2>/dev/null || true

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
    # arch:$ARCH in the seed because the packed binaries (node, rg,
    # micro) are architecture-specific. Without it, an x64 and an arm64
    # host sharing $TOOLS_DIR (NAS-mounted cache, Apple Silicon dev
    # switching between Rosetta and native, CI matrix with a shared
    # build cache) collide on the same `base-*.tar.xz` filename and
    # inject the wrong binaries — the agent then fails to exec with an
    # opaque ELF/Mach-O error. Matches the agent-tier seed below which
    # already includes $ARCH.
    BASE_HASH=$(sha256 "base-arch:$ARCH-node:$NODE_VER-rg:$RG_VER-micro:$MICRO_VER")
    BASE_ARCHIVE="$TOOLS_DIR/base-$BASE_HASH.tar.xz"
  fi
  # Shim template bytes — both tool tier (pnpm) and agent tier (node-
  # bundle agents) render this template, so changes to it must bust
  # both tier caches. Loaded once if either is unpinned and CR-stripped
  # so Windows-side (CRLF) and Linux-side (LF) hashes match.
  if [ -z "${OPT_TOOL_HASH:-}" ] || [ -z "${OPT_AGENT_HASH:-}" ]; then
    _shim_tmpl=$(tr -d '\r' < "$PROJECT_ROOT/bin/node-shim.sh.tmpl")
  fi
  if [ -n "${OPT_TOOL_HASH:-}" ]; then
    TOOL_ARCHIVE=$(resolve_archive "tool" "$OPT_TOOL_HASH")
  else
    # arch:$ARCH covers uv (per-arch native binary). pnpm is now JS,
    # so its bytes are arch-agnostic — but the archive is shared with
    # uv, so $ARCH stays in the seed. Include shim template since
    # pnpm's `pnpm` entry is the rendered shim.
    TOOL_HASH=$(sha256 "tool-arch:$ARCH-pnpm:$PNPM_VER-uv:$UV_VER-shim:$_shim_tmpl")
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
    AGENT_HASH=$(sha256 "agent:$AGENT-ver:$AGENT_VER-arch:$ARCH-manifest:$_manifest_src-manifest-sh:$_manifest_sh-wrapper:$_wrapper_src-shim:$_shim_tmpl")
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
