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

# ── WSL distro ──

$archiveHash = & $sha256 "$baseArchive-$toolArchive-$claudeArchive"
$workdirHash = & $sha256 $PWD.Path
$distroName = "claude-$workdirHash"
$distroDir = "$env:LocalAppData\$distroName"
$stampFile = "$distroDir\.archive-hash"

$distroExists = $false
wsl -d $distroName -- true 2>$null
if ($LASTEXITCODE -eq 0) { $distroExists = $true }

$needsImport = (-not $distroExists)
if ($distroExists) {
  if (-not [IO.File]::Exists($stampFile) -or [IO.File]::ReadAllText($stampFile).Trim() -ne $archiveHash) {
    $needsImport = $true
  }
}

if ($needsImport) {
  if ($distroExists) { wsl --unregister $distroName 2>$null }

  # Build base image and export as tarball for WSL import
  $imageTag = "claude-base-$(& $sha256 ([IO.File]::ReadAllText("$projectRoot\Containerfile") + "-$Image"))"
  podman image exists $imageTag 2>$null
  if ($LASTEXITCODE -ne 0 -or $ForcePull) {
    $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $imageTag)
    if ($ForcePull) { $buildArgs += '--no-cache' }
    $buildArgs += $projectRoot
    Invoke-Must podman @buildArgs
  }
  $exportCtr = (Invoke-Must podman container create $imageTag true)
  try {
    Invoke-Must podman container export $exportCtr -o "$env:TEMP\claude-base.tar"
  }
  finally {
    podman container rm $exportCtr 2>$null
  }

  [IO.Directory]::CreateDirectory($distroDir) > $null
  try {
    Invoke-Must wsl --import $distroName $distroDir "$env:TEMP\claude-base.tar"
  }
  finally {
    [IO.File]::Delete("$env:TEMP\claude-base.tar")
  }

  # Inject tool archives BEFORE disabling automount (needs /mnt/c/ access)
  foreach ($archive in $baseArchive, $toolArchive, $claudeArchive) {
    $wslArchive = & $wslSrc $archive
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, "mkdir -p /home/claude/.local/bin && tar -xJf '$wslArchive' -C /home/claude/.local/bin/ && chmod +x /home/claude/.local/bin/*`n")
    $wslTmp = & $wslSrc $tmp
    try { Invoke-Must wsl -d $distroName -u root -- sh $wslTmp }
    finally { [IO.File]::Delete($tmp) }
  }

  # Rename: claude → claude-bin, claude-wrapper → claude
  Invoke-Must wsl -d $distroName -u root -- sh -c '
    mv /home/claude/.local/bin/claude /home/claude/.local/bin/claude-bin &&
    mv /home/claude/.local/bin/claude-wrapper /home/claude/.local/bin/claude
  '

  # Write wsl.conf and terminate so it takes effect
  Invoke-Must wsl -d $distroName -u root -- sh -c '
    cat > /etc/wsl.conf << EOF
[automount]
enabled = false
[interop]
enabled = false
appendWindowsPath = false
[user]
default = claude
EOF'
  wsl --terminate $distroName 2>$null
  [IO.File]::WriteAllText($stampFile, $archiveHash)
}

# ── Mount and configure ──

$winWorkdir = $PWD.Path

Invoke-Must wsl -d $distroName -u root -- sh -c "
  mkdir -p /var/workdir &&
  mount -t drvfs '$($winWorkdir.Replace("'", "'\''"))' /var/workdir
"

# ── Launch with cleanup ──

$envArgs = 'CLAUDE_CONFIG_DIR=/var/workdir/.claude'
if ($WithDnf) { $envArgs += ' CLAUDE_ENABLE_DNF=1' }

try {
  Invoke-Must wsl -d $distroName --cd /var/workdir -- sh -c "
    exec env $envArgs `$HOME/.local/bin/claude --dangerously-skip-permissions
  "
}
finally {
  wsl --terminate $distroName 2>$null
  wsl --unregister $distroName 2>$null
}
