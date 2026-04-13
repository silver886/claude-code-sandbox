#!/bin/sh
# init-config.sh — stage system-scope Claude config into the project's
# .claude/.system directory. Sourced (not executed).
#
# Sets: CONFIG_DIR, SYSTEM_DIR, CONFIG_FILES, RO_FILES, RO_DIRS
#       (space-separated lists of writable file names, ro file names, ro dir names)
#
# Layout (host side, inside the project being sandboxed):
#
#   $PWD/.claude/                — project scope, untouched (Claude reads it directly)
#   $PWD/.claude/.system/        — system scope, managed here
#     ├── ro/                    — wiped + re-copied each launch
#     │   ├── CLAUDE.md, keybindings.json
#     │   └── rules/, commands/, agents/, output-styles/, skills/<name>/
#     ├── rw/                    — `ln -f` each launch (idempotent)
#     │   └── .credentials.json, settings.json, .claude.json (hardlinks → $CONFIG_DIR)
#     ├── cr/                    — created at runtime by Claude; persists per
#     │                            project. No speculative subdirs are
#     │                            pre-created — Claude mkdirs whatever it
#     │                            needs on demand under the cr/-as-base bind.
#     │                            (The only entries we touch in cr/ are
#     │                            mount-target placeholders for the per-file
#     │                            and per-subdir bind layout — see the loop
#     │                            at the bottom of init_config_dir().)
#     └── .mask/                 — empty dir, used as a bind source to
#                                  mask .system/ from project scope inside
#                                  the sandbox
#
# The 3 writable files are hardlinked into rw/ so the sandbox's bind
# source shares an inode with $CONFIG_DIR/<f>: in-place writes inside
# the sandbox propagate back to ~/.claude immediately. The mount-point
# bind gives EBUSY on rename()/unlink() so Claude Code's atomic-replace
# falls back to in-place writeFileSync(), preserving the shared inode.
#
# In the sandbox the launcher assembles all three buckets at
# CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox via per-file/per-subdir bind
# mounts (see bin/setup-system-mounts.sh and the container -v lists). The
# `.system/` dir on host is then masked from project scope by bind-mounting
# `.mask/` (empty) on top of /var/workdir/.claude/.system inside the
# sandbox, so project-scoped reads under .claude/ never see system-scope
# files. We use a bind of an empty dir instead of `--tmpfs` because podman
# `--tmpfs` over a path inside another `-v` mount has been observed to
# silently no-op on some podman versions.
#
# Why ro/ is wiped every launch: any in-session mutation of the copies
# cannot reach the host (separate inodes), and removing the dir before
# re-copying ensures upstream deletions in $CONFIG_DIR propagate.
#
# Why cr/ persists: session history is per-project state. We do not
# pre-create any speculative subdirs — Claude mkdirs whatever it needs
# at runtime under the cr/-as-base bind mount, which is fully writable
# to the unprivileged sandbox user. The only entries we ever place in
# cr/ are mount-target placeholders for the per-file/per-subdir bind
# overlays (see the placeholder loop at the bottom of init_config_dir).

# Resolve a path through all symlinks to the final target.
# Portable: uses only readlink (one level) in a loop, no -f flag.
_SYMLOOP_MAX=$(getconf SYMLOOP_MAX 2>/dev/null) || _SYMLOOP_MAX=""
case "$_SYMLOOP_MAX" in ''|undefined|-1) _SYMLOOP_MAX=40 ;; esac

_realpath() {
  _p="$1" _n=0
  while [ -L "$_p" ]; do
    _n=$((_n + 1))
    if [ "$_n" -gt "$_SYMLOOP_MAX" ]; then
      echo "Symlink chain too deep: $1" >&2; return 1
    fi
    _d=$(cd -P "$(dirname "$_p")" && pwd)
    _p=$(readlink "$_p")
    case "$_p" in /*) ;; *) _p="$_d/$_p" ;; esac
  done
  _d=$(cd -P "$(dirname "$_p")" && pwd)
  printf '%s/%s' "$_d" "$(basename "$_p")"
}

# Copy a read-only source file into the ro/ staging area. No chmod is
# needed: the ro/ bucket is wiped + re-copied each launch, and ro
# enforcement happens at mount level (remount,bind,ro) inside the
# sandbox. Resolves symlinks in the source so the copy reflects the
# real upstream content.
_stage_ro_file() {
  _src=$(_realpath "$1")
  _dest="$2"
  cp -f "$_src" "$_dest"
}

# Hardlink a writable source file into the rw/ staging area. Hardlink
# (not copy) so writes from inside the sandbox propagate back to the
# canonical $CONFIG_DIR/<f> via the shared inode. Resolves symlinks so
# the link is to the real target, not to the symlink itself.
_stage_rw_file() {
  _src=$(_realpath "$1")
  _dest="$2"
  ln -f "$_src" "$_dest" || {
    echo "Cannot hardlink $_src -> $_dest (cross-filesystem?). Writable config requires same filesystem for host sync." >&2
    exit 1
  }
}

# Resolve a directory through any symlink chain to its physical path.
# Subshell keeps cwd unchanged. Empty output if the path is invalid.
_resolve_dir() {
  (cd -P "$1" 2>/dev/null && pwd)
}

init_config_dir() {
  CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ ! -d "$CONFIG_DIR" ]; then
    echo "Claude config directory not found: $CONFIG_DIR" >&2; exit 1
  fi

  SYSTEM_DIR="$PWD/.claude/.system"

  # Warn if the project has a .gitignore that doesn't exclude the
  # system bucket — credentials and per-project session history live
  # there and absolutely should not be committed. Match either an
  # explicit `.claude/.system` entry or any parent that already
  # excludes it (`.claude` / `.claude/`). Don't modify user files;
  # just print the warning once per launch.
  if [ -f "$PWD/.gitignore" ] && ! grep -qE '^[[:space:]]*/?\.claude(/(\.system)?/?)?[[:space:]]*$' "$PWD/.gitignore" 2>/dev/null; then
    echo "warning: $PWD/.gitignore does not exclude .claude/.system/ — your hardlinked credentials and session history live there. Add: .claude/.system/" >&2
  fi

  mkdir -p "$SYSTEM_DIR/rw" "$SYSTEM_DIR/cr" "$SYSTEM_DIR/.mask"

  # Wipe + re-create ro/ so upstream deletions in $CONFIG_DIR propagate
  # and any in-session tampering on copies is undone for the next launch.
  rm -rf "$SYSTEM_DIR/ro"
  mkdir -p "$SYSTEM_DIR/ro"

  # Writable files → rw/ (hardlinks). Refreshed every launch (ln -f is
  # idempotent and re-points to the current host inode).
  CONFIG_FILES=""
  for _f in .credentials.json settings.json .claude.json; do
    [ -f "$CONFIG_DIR/$_f" ] || continue
    CONFIG_FILES="$CONFIG_FILES $_f"
    _stage_rw_file "$CONFIG_DIR/$_f" "$SYSTEM_DIR/rw/$_f"
  done

  # Read-only single files → ro/
  RO_FILES=""
  for _f in CLAUDE.md keybindings.json; do
    [ -f "$CONFIG_DIR/$_f" ] || continue
    RO_FILES="$RO_FILES $_f"
    _stage_ro_file "$CONFIG_DIR/$_f" "$SYSTEM_DIR/ro/$_f"
  done

  # Read-only directories (flat). Each $CONFIG_DIR/<d> may be a symlink chain.
  RO_DIRS=""
  for _d in rules commands agents output-styles; do
    [ -d "$CONFIG_DIR/$_d" ] || continue
    _src_dir=$(_resolve_dir "$CONFIG_DIR/$_d")
    [ -n "$_src_dir" ] || continue
    RO_DIRS="$RO_DIRS $_d"
    mkdir -p "$SYSTEM_DIR/ro/$_d"
    for _f in "$_src_dir"/*; do
      [ -f "$_f" ] || continue
      _stage_ro_file "$_f" "$SYSTEM_DIR/ro/$_d/$(basename "$_f")"
    done
  done

  # Skills (two-level: skills/<name>/<files>).
  # Both the skills/ dir and each individual skill dir may be symlinks.
  if [ -d "$CONFIG_DIR/skills" ]; then
    _skills_src=$(_resolve_dir "$CONFIG_DIR/skills")
    if [ -n "$_skills_src" ]; then
      RO_DIRS="$RO_DIRS skills"
      mkdir -p "$SYSTEM_DIR/ro/skills"
      for _skill_dir in "$_skills_src"/*/; do
        [ -d "$_skill_dir" ] || continue
        _name=$(basename "$_skill_dir")
        _skill_src=$(_resolve_dir "$_skill_dir")
        [ -n "$_skill_src" ] || continue
        mkdir -p "$SYSTEM_DIR/ro/skills/$_name"
        for _f in "$_skill_src"/*; do
          [ -f "$_f" ] || continue
          _stage_ro_file "$_f" "$SYSTEM_DIR/ro/skills/$_name/$(basename "$_f")"
        done
      done
    fi
  fi

  # cr/ placeholders — created AFTER discovery so we only place files /
  # dirs that the launcher will actually bind-mount on top of. Without
  # these, podman would auto-create empty placeholder files inside
  # cr/ on the host when it processes the nested -v flags, leaking
  # unpredictable junk into the project. With them, the bind targets
  # are stable empty files/dirs that get shadowed at mount time.
  for _f in $CONFIG_FILES $RO_FILES; do
    [ -e "$SYSTEM_DIR/cr/$_f" ] || : > "$SYSTEM_DIR/cr/$_f"
  done
  for _d in $RO_DIRS; do
    mkdir -p "$SYSTEM_DIR/cr/$_d"
  done
}
