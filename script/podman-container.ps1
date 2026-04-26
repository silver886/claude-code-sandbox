param(
  [string]$Agent = 'claude',
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$AgentHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$AllowDnf,
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'

$LogLevel = $LogLevel.ToUpperInvariant()
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
$agent = $Agent
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optAgentHash = $AgentHash
$forcePull = $ForcePull.IsPresent

. $initLauncher
. $buildBaseImage

Write-Log I run launch "podman container run $imageTag ($agent)"

# ── Run ──
#
# System config assembly via podman -v stacking:
#   1. cr/ as the base of $crateDir (rw, persists per project)
#   2. rw/<f> per-file mounts shadow cr at <f> with host hardlinks
#   3. ro/<x>:ro per-file/per-subdir mounts shadow cr at <x>, read-only
#   4. .mask/ bind-mounted (read-only) over /var/workdir/<projectDir>/.system

$systemDirWsl = & $wslSrc $systemDir
$extraArgs = @('-v', "${systemDirWsl}/cr:${crateDir}")
foreach ($f in $configFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/rw/${f}:${crateDir}/${f}"
}
foreach ($f in $roFiles) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${f}:${crateDir}/${f}:ro"
}
foreach ($d in $roDirs) {
  $extraArgs += '-v'
  $extraArgs += "${systemDirWsl}/ro/${d}:${crateDir}/${d}:ro"
}
$extraArgs += '-v'
$extraArgs += "${systemDirWsl}/.mask:/var/workdir/${agentProjectDir}/.system:ro"
if ($AllowDnf) { $extraArgs += '--env', 'CRATE_ALLOW_DNF=1' }

Invoke-Must podman container run --interactive --tty --rm `
  '--userns=keep-id:uid=24368,gid=24368' `
  -v "$(& $wslSrc $baseArchive):/tmp/base.tar.xz:ro" `
  -v "$(& $wslSrc $toolArchive):/tmp/tool.tar.xz:ro" `
  -v "$(& $wslSrc $agentArchive):/tmp/agent.tar.xz:ro" `
  -v "$(& $wslSrc $PWD.Path):/var/workdir" `
  --workdir /var/workdir `
  @extraArgs `
  $imageTag `
  --log-level $LogLevel
