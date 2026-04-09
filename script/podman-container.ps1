param(
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$ClaudeHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest',
  [switch]$WithDnf
)
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir
& "$projectRoot\lib\Ensure-Credential.ps1"

. "$projectRoot\lib\Init-Config.ps1"
. "$projectRoot\lib\Tools.ps1"
. $initConfigDir

# ── Build tool archives ──

. $detectArch
$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optClaudeHash = $ClaudeHash
$forcePull = $ForcePull.IsPresent
. $buildToolArchives

# ── Build base image ──

$imageTag = "claude-base-$(& $sha256 ([IO.File]::ReadAllText("$projectRoot\Containerfile") + "-$Image"))"
podman image exists $imageTag 2>$null
if ($LASTEXITCODE -ne 0 -or $ForcePull) {
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $imageTag)
  if ($ForcePull) { $buildArgs += '--no-cache' }
  $buildArgs += $projectRoot
  Invoke-Must podman @buildArgs
}

# ── Run ──

# Config file mounts (live sync with host config dir)
$extraArgs = @('--env', 'CLAUDE_CONFIG_DIR=/var/workdir/.claude')
foreach ($f in $configFiles) {
  $extraArgs += '-v'
  $extraArgs += "$(& $wslSrc ([IO.Path]::Combine($configDir, $f))):/var/workdir/.claude/$f"
}
if ($WithDnf) { $extraArgs += '--env', 'CLAUDE_ENABLE_DNF=1' }

Invoke-Must podman container run --interactive --tty --rm `
  '--userns=keep-id:uid=1000,gid=1000' `
  -v "$(& $wslSrc $baseArchive):/tmp/base.tar.xz:ro" `
  -v "$(& $wslSrc $toolArchive):/tmp/tool.tar.xz:ro" `
  -v "$(& $wslSrc $claudeArchive):/tmp/claude.tar.xz:ro" `
  -v "$(& $wslSrc $PWD.Path):/var/workdir" `
  --workdir /var/workdir `
  @extraArgs `
  $imageTag
