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

# Threshold filtering reads `$script:LogLevel` from the dot-source
# caller's script scope. The launcher (or Ensure-Credential.ps1 when
# run standalone) sets $script:LogLevel from its -LogLevel param.
# This avoids touching $env:, which is process-wide in PowerShell
# and would pollute the caller's pwsh session after the script exits.
#
# Child processes that need to inherit the level get LOG_LEVEL
# injected explicitly at the boundary call site:
#
#   Ensure-Credential.ps1  & ./lib/Ensure-Credential.ps1 -LogLevel $script:LogLevel
#   podman container       podman run --env LOG_LEVEL=$LogLevel …
#   wsl -u root            wsl … env LOG_LEVEL=$LogLevel cmd
#   sudo (in sandbox)      sudo --preserve-env=LOG_LEVEL cmd  (env set by podman --env)
#
# Levels:
#   I   show everything (verbose; opt-in)
#   W   show warnings + errors (default; quiet on success)
#   E   show errors only

function Write-Log {
  param(
    [Parameter(Mandatory)][ValidateSet('I', 'W', 'E')][string]$Level,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Event,
    [string]$Msg = ''
  )
  $threshold = switch ($script:LogLevel) { 'I' { 1 } 'E' { 3 } default { 2 } }
  $msgLevel = switch ($Level) { 'W' { 2 } 'E' { 3 } default { 1 } }
  if ($msgLevel -lt $threshold) { return }
  $ts = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $line = '{0} {1} {2,-16} {3,-14} {4}' -f $ts, $Level, $Stage, $Event, $Msg
  $color = switch ($Level) {
    'W' { 'Yellow' }
    'E' { 'Red' }
    default { 'DarkGray' }
  }
  Write-Host $line -ForegroundColor $color
}
