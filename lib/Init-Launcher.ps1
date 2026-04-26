# Init-Launcher.ps1 — shared launcher initialization (multi-agent).
# Dot-sourced (not executed). Requires: $projectRoot, $agent (set by caller).
#
# Sources Agent.ps1, Init-Config.ps1, Tools.ps1. Provides $initLauncher
# which runs credential check, config init, arch detection, and
# tool archive build.
#
# Also provides:
#   Invoke-Must — run a native command and throw on non-zero exit
#   $wslSrc     — convert a Windows path to a WSL absolute path

function Invoke-Must {
  $cmd = $args[0]
  $cmdArgs = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
  & $cmd @cmdArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed (exit $LASTEXITCODE): $cmd $($cmdArgs -join ' ')"
  }
}

# Log.ps1 first so every downstream lib can call Write-Log.
. "$projectRoot\lib\Log.ps1"
. "$projectRoot\lib\Agent.ps1"
. "$projectRoot\lib\Init-Config.ps1"
. "$projectRoot\lib\Tools.ps1"

$wslSrc = { param($p)
  $abs = [IO.Path]::GetFullPath($p)
  if ($abs.Length -lt 3 -or $abs[1] -ne ':') {
    throw "wslSrc: non-drive-letter path not supported: $abs"
  }
  '/mnt/' + $abs.Substring(0, 1).ToLower() + $abs.Substring(2).Replace('\', '/')
}

$initLauncher = {
  Invoke-AgentLoad
  Write-Log I launcher start "CRATE ($agent) $($MyInvocation.ScriptName)"
  & "$projectRoot\lib\Ensure-Credential.ps1" -Agent $agent -LogLevel $script:LogLevel
  . $initConfigDir
  . $detectArch
  . $buildToolArchives
}
