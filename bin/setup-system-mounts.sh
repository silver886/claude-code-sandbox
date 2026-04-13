#!/bin/sh
# setup-system-mounts.sh — assemble CLAUDE_CONFIG_DIR inside a sandbox
# from a project's $PWD/.claude/.system/{ro,rw,cr} layout, and bind-mask
# .system/ from project scope using the empty .system/.mask dir.
#
# Run as root inside the sandbox (via `sudo` on the VM/WSL backends —
# claude itself NEVER runs as root). Container backends do not need this
# script: podman -v flags do the equivalent assembly directly.
#
# Args:
#   --workdir DIR        host workdir mount point (default: /var/workdir)
#   --target  DIR        sandbox config dir       (default: /etc/claude-code-sandbox)
#   --config-files "..." space-separated rw file basenames (from $CONFIG_FILES).
#                        Sourced from $WORKDIR/.claude/.system/rw/<f>, which
#                        init-config.sh populates with hardlinks to the
#                        canonical $CONFIG_DIR/<f> on every launch.
#   --ro-files    "..." space-separated ro file basenames (from $RO_FILES)
#   --ro-dirs     "..." space-separated ro dir  basenames (from $RO_DIRS)
#
# Assembly steps (in order — see plan doc for the vfkit rationale):
#   1. mkdir target
#   2. bind cr/ as base — Claude's runtime writes (projects/, todos/, …)
#      land back in $PWD/.claude/.system/cr on the host
#   3. per-file rw overlay — bind rw/$f → target/$f. Mount-point gives
#      EBUSY → in-place writeFileSync → hardlink preserved → host sync
#   4. per-file/per-subdir ro overlay — bind + remount,bind,ro
#   5. mask $workdir/.claude/.system by bind-mounting .system/.mask
#      (empty dir) on top of it, then remount,bind,ro. Hides system
#      scope from project-scope reads under .claude/. Done LAST so
#      the binds in 2-4 capture the real host inodes before the mask
set -eu

WORKDIR=/var/workdir
TARGET=/etc/claude-code-sandbox
CONFIG_FILES=""
RO_FILES=""
RO_DIRS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir)      WORKDIR="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --config-files) CONFIG_FILES="$2"; shift 2 ;;
    --ro-files)     RO_FILES="$2"; shift 2 ;;
    --ro-dirs)      RO_DIRS="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SYSTEM="$WORKDIR/.claude/.system"

mkdir -p "$TARGET"

# Step 2: cr/ as the base mount. Anything Claude creates under
# CLAUDE_CONFIG_DIR (sessions, backups, …) is written to this bucket and
# persists on the host across sandbox launches.
mount --bind "$SYSTEM/cr" "$TARGET"

# Step 3: writable file overlay. Source is the rw/ hardlink staged by
# init-config (which always populates rw/ with hardlinks to the
# canonical $CONFIG_DIR/<f>). `touch` first because cr/ doesn't contain
# these names — the mount target must exist for `mount --bind`.
for _f in $CONFIG_FILES; do
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/rw/$_f" "$TARGET/$_f"
done

# Step 4a: read-only single files
for _f in $RO_FILES; do
  touch "$TARGET/$_f"
  mount --bind "$SYSTEM/ro/$_f" "$TARGET/$_f"
  mount -o remount,bind,ro "$TARGET/$_f"
done

# Step 4b: read-only directories
for _d in $RO_DIRS; do
  mkdir -p "$TARGET/$_d"
  mount --bind "$SYSTEM/ro/$_d" "$TARGET/$_d"
  mount -o remount,bind,ro "$TARGET/$_d"
done

# Step 5: mask .system/ from project scope by bind-mounting the empty
# .mask/ dir over it. After this, anything reading under
# $WORKDIR/.claude/.system sees an empty dir — but the binds set up
# above continue to serve real content via $TARGET because mount --bind
# captures the source inode at bind time, not on every access.
# Bind-of-empty-dir instead of tmpfs because tmpfs has been observed to
# silently no-op when nested inside another bind in some environments.
mount --bind "$SYSTEM/.mask" "$SYSTEM"
mount -o remount,bind,ro "$SYSTEM"
