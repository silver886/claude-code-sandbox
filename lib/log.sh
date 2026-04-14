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

# log <lvl> <stage> <event> <message>
log() {
  printf '%s %s %-16s %-14s %s\n' "$(_log_ts)" "$1" "$2" "$3" "$4" >&2
}
