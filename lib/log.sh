#!/bin/sh
# log.sh — structured logger for launcher and lib scripts. Sourced
# (not executed). Provides `log` with a fixed-width 5-column format:
#
#   <TS>                     <LVL> <STAGE>          <EVENT>        <MSG>
#   2026-04-14T15:04:05.123Z I     tools.base       cache-hit      base-2e029a8…
#
# Columns (fixed width — every line has identical layout regardless
# of how long the launcher has been running, what host it's on, etc):
#   TS       — RFC 3339 UTC timestamp with millisecond precision
#              (`yyyy-MM-ddTHH:mm:ss.fffZ`, always 24 chars). We use
#              `.000`-style fixed three-digit ms rather than Go's
#              `.999` (which strips trailing zeros) so the column
#              width is constant.
#   LVL      — single char: I (info) | W (warn) | E (error)
#   STAGE    — top-level area (cred, config, tools.base, image, vm,
#              distro, mounts, run, launcher, …) padded to 16. Sized
#              with headroom over the longest current stage so future
#              stages don't desync the message column.
#   EVENT    — verb (cache-hit, cache-pin, downloading, packing,
#              cached, start, done, ok, skip, fail, …) padded to 14
#   MSG      — free-form trailing string
#
# All output goes to stderr so stdout pipelines from the launchers
# stay clean.

# Probe sub-second support. POSIX `date +%N` is a GNU extension; BSD
# date returns the literal "N". On BSD-only hosts we fall back to a
# literal `.000` so the column width is preserved.
_log_probe=$(date +%3N 2>/dev/null)
case "$_log_probe" in
  ''|N|*[!0-9]*) _log_has_ms="" ;;
  *)             _log_has_ms=1 ;;
esac
unset _log_probe

if [ -n "$_log_has_ms" ]; then
  _log_ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
else
  _log_ts() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
fi

# Threshold filtering reads `$LOG_LEVEL` as a plain shell variable
# (not an env var) — it lives in the launcher process and dies with
# it. Child processes that need to inherit the level get LOG_LEVEL
# injected explicitly at the boundary call site:
#
#   ensure-credential.sh   LOG_LEVEL=$LOG_LEVEL ./lib/ensure-credential.sh
#   podman container       podman run --env LOG_LEVEL=$LOG_LEVEL …
#   podman machine ssh     ssh "export LOG_LEVEL=$LOG_LEVEL && cmd"
#   wsl -u root            wsl … env LOG_LEVEL=$LOG_LEVEL cmd
#   sudo (in sandbox)      sudo --preserve-env=LOG_LEVEL cmd  (env set by podman --env)
#
# The bin/* in-sandbox scripts read LOG_LEVEL from their *process
# environment* (delivered by podman --env / wsl env / sudo
# --preserve-env). That's the correct transport at the boundary and
# avoids touching the launcher's env so the host shell is never
# polluted.
#
# Levels:
#   LOG_LEVEL=I   show everything (verbose; opt-in)
#   LOG_LEVEL=W   show warnings + errors (default; quiet on success)
#   LOG_LEVEL=E   show errors only
#
# $LOG_LEVEL is read on every call so the launcher can parse
# --log-level after sourcing this file.

# log <lvl> <stage> <event> <message>
log() {
  _t=2; case "${LOG_LEVEL:-W}" in I) _t=1 ;; E) _t=3 ;; esac
  _m=1; case "$1"               in W) _m=2 ;; E) _m=3 ;; esac
  [ "$_m" -lt "$_t" ] && return 0
  printf '%s %s %-16s %-14s %s\n' "$(_log_ts)" "$1" "$2" "$3" "$4" >&2
}
