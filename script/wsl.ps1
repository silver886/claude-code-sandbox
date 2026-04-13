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
. "$projectRoot\lib\Init-Launcher.ps1"
. "$projectRoot\lib\Build-Image.ps1"

$optBaseHash = $BaseHash; $optToolHash = $ToolHash; $optClaudeHash = $ClaudeHash
$forcePull = $ForcePull.IsPresent
$distroName = $null

try {
  . $initLauncher

  # ── WSL distro ──

  $distroSrc = (& $imageSrc) +
               [IO.File]::ReadAllText("$projectRoot\config\wsl.conf") +
               [IO.File]::ReadAllText("$projectRoot\bin\setup-system-mounts.sh")
  $archiveHash = & $sha256 "$baseArchive-$toolArchive-$claudeArchive-$distroSrc-$Image"
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
    . $buildBaseImage
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

    # Extract tool archives and set up binaries (before disabling automount — needs /mnt/c/)
    $wslSetup = & $wslSrc "$projectRoot\bin\setup-tools.sh"
    $wslArchives = @()
    foreach ($archive in $baseArchive, $toolArchive, $claudeArchive) {
      $wslArchives += & $wslSrc $archive
    }
    Invoke-Must wsl -d $distroName -u root -- env CLAUDE_BIN_DIR=/home/claude/.local/bin sh $wslSetup @wslArchives

    # Bake setup-system-mounts.sh into the distro at a stable in-distro
    # path. Must happen here (while /mnt/c is still available via
    # automount) because after wsl.conf is installed below, automount
    # is off and /mnt/c is gone — the next launcher invocation can't
    # reach the host file. The path matches Containerfile's existing
    # /usr/local/libexec/claude-code-sandbox/ which the podman-exported
    # rootfs already contains.
    $wslSetupSys = & $wslSrc "$projectRoot\bin\setup-system-mounts.sh"
    Invoke-Must wsl -d $distroName -u root -- cp $wslSetupSys /usr/local/libexec/claude-code-sandbox/setup-system-mounts.sh
    Invoke-Must wsl -d $distroName -u root -- chmod +x /usr/local/libexec/claude-code-sandbox/setup-system-mounts.sh

    # Write wsl.conf and terminate so it takes effect
    $wslConf = & $wslSrc "$projectRoot\config\wsl.conf"
    Invoke-Must wsl -d $distroName -u root -- cp $wslConf /etc/wsl.conf
    wsl --terminate $distroName 2>$null
    [IO.File]::WriteAllText($stampFile, $archiveHash)
  }

  # ── Mount and configure ──
  #
  # Single drvfs mount: workdir → /var/workdir. .system\rw\ (hardlinks
  # to the canonical config files, populated by init-config on every
  # launch) rides along, and the in-distro setup script binds from there.

  $winWorkdir = $PWD.Path
  Invoke-Must wsl -d $distroName -u root -- sh -c "
    mkdir -p /var/workdir &&
    mount -t drvfs '$($winWorkdir.Replace("'", "'\''"))' /var/workdir
  "

  # Run setup-system-mounts.sh from its baked-in path inside the distro
  # (installed during the import block above). claude itself is launched
  # below as the unprivileged claude user — sudo/root is only used here
  # to do the mount syscalls.
  Invoke-Must wsl -d $distroName -u root -- /usr/local/libexec/claude-code-sandbox/setup-system-mounts.sh `
    --workdir /var/workdir `
    --target /etc/claude-code-sandbox `
    --config-files "$($configFiles -join ' ')" `
    --ro-files "$($roFiles -join ' ')" `
    --ro-dirs "$($roDirs -join ' ')"

  # ── Launch ──

  $envArgs = 'CLAUDE_CONFIG_DIR=/etc/claude-code-sandbox'
  if ($WithDnf) { $envArgs += ' CLAUDE_ENABLE_DNF=1' }

  Invoke-Must wsl -d $distroName --cd /var/workdir -- sh -c "
    exec env $envArgs `$HOME/.local/bin/claude --dangerously-skip-permissions
  "
}
finally {
  if ($distroName) {
    try { wsl --terminate $distroName 2>$null } catch {}
    try { wsl --unregister $distroName 2>$null } catch {}
  }
}
