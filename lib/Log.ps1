# Log.ps1 — structured logger for launcher and lib scripts. Dot-sourced
# (not executed). Provides Write-Log with a fixed-width 5-column format
# matching lib/log.sh exactly:
#
#   <TS>                     <LVL> <STAGE>          <EVENT>        <MSG>
#   2026-04-14T15:04:05.123Z I     tools.base       cache-hit      base-2e029a8…
#
# Columns (fixed width on every line, regardless of host or runtime):
#   TS       — RFC 3339 UTC timestamp with millisecond precision
#              (yyyy-MM-ddTHH:mm:ss.fffZ, always 24 chars)
#   LVL      — single char: I | W | E (validated)
#   STAGE    — area (cred, config, tools.base, image, distro, …) padded 16
#   EVENT    — verb padded 14
#   MSG      — free-form trailing string
#
# I is dim, W yellow, E red. Output goes to the host stream.

function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet('I', 'W', 'E')][string]$Level,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Event,
    [string]$Msg = ''
  )
  $ts = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $line = '{0} {1} {2,-16} {3,-14} {4}' -f $ts, $Level, $Stage, $Event, $Msg
  $color = switch ($Level) {
    'W' { 'Yellow' }
    'E' { 'Red' }
    default { 'DarkGray' }
  }
  Write-Host $line -ForegroundColor $color
}
