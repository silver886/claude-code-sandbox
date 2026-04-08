param(
  [string]$BaseHash = '',
  [string]$ToolHash = '',
  [string]$ClaudeHash = '',
  [switch]$ForcePull,
  [string]$Image = 'fedora:latest'
)
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
& "$scriptDir\Ensure-Credential.ps1"

. "$scriptDir\lib.ps1"

# ── Build tool archives ──

. $detectArch
$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optClaudeHash = $ClaudeHash
$forcePull = $ForcePull.IsPresent
. $buildToolArchives

# ── Build base image ──

$imageTag = "claude-base-$(& $sha256 ([IO.File]::ReadAllText("$scriptDir\Containerfile") + "-$Image"))"
podman image exists $imageTag 2>$null
if ($LASTEXITCODE -ne 0 -or $ForcePull) {
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $imageTag)
  if ($ForcePull) { $buildArgs += '--no-cache' }
  $buildArgs += $scriptDir
  Invoke-Must podman @buildArgs
}

# ── Run ──

Invoke-Must podman container run --interactive --tty --rm `
  '--userns=keep-id:uid=1000,gid=1000' `
  --security-opt label=disable `
  -v "$(& $wslSrc $baseArchive):/tmp/base.tar.gz:ro" `
  -v "$(& $wslSrc $toolArchive):/tmp/tool.tar.gz:ro" `
  -v "$(& $wslSrc $claudeArchive):/tmp/claude.tar.gz:ro" `
  -v "$(& $wslSrc "$scriptDir/.claude.json"):/home/claude/.claude.json" `
  -v "$(& $wslSrc "$scriptDir/settings.json"):/home/claude/.claude/settings.json" `
  -v "$(& $wslSrc "$scriptDir/.credentials.json"):/home/claude/.claude/.credentials.json" `
  -v "$(& $wslSrc $PWD.Path):/var/workdir" `
  --workdir /var/workdir `
  $imageTag
