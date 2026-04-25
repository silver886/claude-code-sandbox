#!/bin/bash
# init-config.sh — stage system-scope agent config into the project's
# <projectDir>/.system directory. Sourced (not executed) by a bash
# launcher (bash arrays + read -d '' are required for NUL-safe iteration).
#
# Requires (from agent.sh): AGENT_CONFIG_DIR, AGENT_PROJECT_DIR, AGENT_MANIFEST.
# Sets:   SYSTEM_DIR
# Sets (bash arrays): CONFIG_FILES, RO_FILES, RO_DIRS
#
# Layout (inside each project being sandboxed):
#
#   $PWD/<projectDir>/             — project scope, untouched
#   $PWD/<projectDir>/.system/     — system scope, managed here
#     ├── ro/     (wiped + re-copied each launch)
#     ├── rw/     (hardlinks to host, `ln -f` idempotent)
#     ├── cr/     (runtime-created; persists per project)
#     └── .mask/  (empty dir — bind source to mask .system/ from proj scope)
#
# RW files are hardlinked so writes inside the sandbox propagate to the
# canonical host config. RO files + dirs are copied (wiped each launch,
# protecting the host from in-session mutation). The cr/ bucket holds
# runtime writes that persist per project.

# Resolve a path through all symlinks to the final target.
_SYMLOOP_MAX=$(getconf SYMLOOP_MAX 2>/dev/null) || _SYMLOOP_MAX=""
case "$_SYMLOOP_MAX" in ''|undefined|-1) _SYMLOOP_MAX=40 ;; esac

_realpath() {
  _p="$1" _n=0
  while [ -L "$_p" ]; do
    _n=$((_n + 1))
    if [ "$_n" -gt "$_SYMLOOP_MAX" ]; then
      log E config fail "symlink chain too deep: $1"; return 1
    fi
    _d=$(cd -P "$(dirname "$_p")" && pwd)
    _p=$(readlink "$_p")
    case "$_p" in /*) ;; *) _p="$_d/$_p" ;; esac
  done
  _d=$(cd -P "$(dirname "$_p")" && pwd)
  printf '%s/%s' "$_d" "$(basename "$_p")"
}

_stage_ro_file() {
  _src=$(_realpath "$1"); _dest="$2"
  cp -f "$_src" "$_dest"
}

_stage_rw_file() {
  _src=$(_realpath "$1"); _dest="$2"
  ln -f "$_src" "$_dest" || {
    log E config fail "cannot hardlink $_src -> $_dest (cross-filesystem?); writable config requires same filesystem for host sync"
    exit 1
  }
}

_resolve_dir() { (cd -P "$1" 2>/dev/null && pwd); }

init_config_dir() {
  log I config start "staging $PWD/$AGENT_PROJECT_DIR/.system"
  if [ ! -d "$AGENT_CONFIG_DIR" ]; then
    log E config fail "$AGENT config directory not found: $AGENT_CONFIG_DIR"
    exit 1
  fi

  SYSTEM_DIR="$PWD/$AGENT_PROJECT_DIR/.system"

  # Warn if the project is a git repo (or worktree) and nothing in
  # .gitignore excludes the system bucket — credentials and per-project
  # session history live there and should not be committed. Match the
  # agent's own project dir ('/.claude/.system', '/.gemini/.system', …)
  # or any parent that already excludes it (e.g. '.claude', '.claude/').
  # Prefer `rg` (its \Q…\E literal region keeps `$_pd` safe without
  # hand-escaping); fall back to `grep -qE` with an explicit ERE escape
  # of `$_pd` when rg isn't on PATH, so a missing rg doesn't produce a
  # false-positive warning.
  _pd="$AGENT_PROJECT_DIR"
  _has_gitignore_entry() {
    if command -v rg >/dev/null 2>&1; then
      rg -q "^[[:space:]]*/?\Q${_pd}\E(/(\.system)?/?)?[[:space:]]*\$" "$1" 2>/dev/null
    else
      _pd_ere=$(printf '%s' "$_pd" | sed 's#[][.*^$\\/]#\\&#g')
      grep -qE "^[[:space:]]*/?${_pd_ere}(/(\.system)?/?)?[[:space:]]*\$" "$1" 2>/dev/null
    fi
  }
  if [ -e "$PWD/.git" ] && { [ ! -f "$PWD/.gitignore" ] || \
       ! _has_gitignore_entry "$PWD/.gitignore"; }; then
    log W config gitignore "$PWD/.gitignore does not exclude $_pd/.system/; add a '$_pd/.system/' entry to keep credentials and session history out of commits"
  fi

  mkdir -p "$SYSTEM_DIR/rw" "$SYSTEM_DIR/cr" "$SYSTEM_DIR/.mask"
  rm -rf "$SYSTEM_DIR/ro"
  mkdir -p "$SYSTEM_DIR/ro"

  # Writable files → rw/ (hardlinks).
  CONFIG_FILES=()
  while IFS= read -r -d '' _f; do
    [ -f "$AGENT_CONFIG_DIR/$_f" ] || continue
    CONFIG_FILES+=("$_f")
    _stage_rw_file "$AGENT_CONFIG_DIR/$_f" "$SYSTEM_DIR/rw/$_f"
  done < <(agent_get_list_nul .files.rw)

  # Read-only single files → ro/
  RO_FILES=()
  while IFS= read -r -d '' _f; do
    [ -f "$AGENT_CONFIG_DIR/$_f" ] || continue
    RO_FILES+=("$_f")
    _stage_ro_file "$AGENT_CONFIG_DIR/$_f" "$SYSTEM_DIR/ro/$_f"
  done < <(agent_get_list_nul .files.ro)

  # Read-only directories (recursive copy). Handles both flat dirs
  # (rules/, commands/, …) and nested ones (skills/<name>/<files>)
  # uniformly via `cp -RL` which dereferences symlink targets.
  RO_DIRS=()
  while IFS= read -r -d '' _d; do
    [ -d "$AGENT_CONFIG_DIR/$_d" ] || continue
    _src_dir=$(_resolve_dir "$AGENT_CONFIG_DIR/$_d")
    [ -n "$_src_dir" ] || continue
    RO_DIRS+=("$_d")
    mkdir -p "$SYSTEM_DIR/ro/$_d"
    # `cp -RL .` copies contents (not the dir itself) and follows
    # symlinks so nested symlinked skill dirs land as real files.
    (cd "$_src_dir" && cp -RL . "$SYSTEM_DIR/ro/$_d/")
  done < <(agent_get_list_nul .files.roDirs)

  # cr/ placeholders for the mount points. Use the ${arr[@]+…} guard so
  # set -u doesn't choke on empty arrays in older bash (3.2 on macOS).
  for _f in ${CONFIG_FILES[@]+"${CONFIG_FILES[@]}"} ${RO_FILES[@]+"${RO_FILES[@]}"}; do
    [ -e "$SYSTEM_DIR/cr/$_f" ] || : > "$SYSTEM_DIR/cr/$_f"
  done
  for _d in ${RO_DIRS[@]+"${RO_DIRS[@]}"}; do
    mkdir -p "$SYSTEM_DIR/cr/$_d"
  done
  log I config done "rw=${#CONFIG_FILES[@]} ro-files=${#RO_FILES[@]} ro-dirs=${#RO_DIRS[@]}"
}
