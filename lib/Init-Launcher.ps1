# Init-Launcher.ps1 — shared launcher initialization.
# Dot-sourced (not executed). Requires: $projectRoot
#
# Sources Init-Config.ps1 and Tools.ps1, then provides $initLauncher
# which runs credential check, config init, arch detection, and
# tool archive build.
#
# Also provides:
#   $wslSrc — convert a Windows path to a WSL absolute path
#
# Caller must set $optBaseHash, $optToolHash, $optClaudeHash, $forcePull
# before invoking $initLauncher.

. "$projectRoot\lib\Init-Config.ps1"
. "$projectRoot\lib\Tools.ps1"

$wslSrc = { param($p) Invoke-Must wsl wslpath -a ($p.Replace('\', '/')) }

$initLauncher = {
  & "$projectRoot\lib\Ensure-Credential.ps1"
  . $initConfigDir
  . $detectArch
  . $buildToolArchives
}
