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
$distroName = $null

try {
  . $initLauncher

  # ── WSL distro ──
  #
  # Every launch imports a fresh distro and the finally block below
  # unregisters it on exit — no reuse across sessions.

  # See script/podman-machine.sh for rationale: 128-bit MD5 → base62 → 22
  # chars, so `crate-<hash>` is 28 chars (under Podman's 30-char cap on
  # macOS; WSL is much looser, but we keep parity).
  $hex = & $md5 $PWD.Path
  # Leading '0' forces non-negative interpretation (BigInteger treats a
  # leading hex digit >=8 as a sign bit, yielding a negative value).
  $num = [System.Numerics.BigInteger]::Parse("0$hex", 'AllowHexSpecifier')
  $b62 = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
  $workdirHash = ''
  while ($num -gt 0) {
    $workdirHash = $b62[[int]($num % 62)] + $workdirHash
    $num = $num / 62
  }
  while ($workdirHash.Length -lt 22) { $workdirHash = '0' + $workdirHash }
  $distroName = "crate-$workdirHash"
  $distroDir = "$env:LocalAppData\$distroName"

  # Clean up any stale distro left over from a crashed prior session.
  wsl -d $distroName -- true 2>$null
  if ($LASTEXITCODE -eq 0) {
    Write-Log I distro unregister "$distroName (stale)"
    wsl --unregister $distroName 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Log W distro unregister-fail "'$distroName' still registered (in use elsewhere?); fresh --import will fail"
    }
  }

  . $buildBaseImage
  Write-Log I distro export "$imageTag -> crate-base.tar"
  $exportCtr = (Invoke-Must podman container create $imageTag true)
  try {
    Invoke-Must podman container export $exportCtr -o "$env:TEMP\crate-base.tar"
  }
  finally {
    podman container rm $exportCtr 2>$null
  }

  [IO.Directory]::CreateDirectory($distroDir) > $null
  try {
    Write-Log I distro import $distroName
    Invoke-Must wsl --import $distroName $distroDir "$env:TEMP\crate-base.tar"
  }
  finally {
    [IO.File]::Delete("$env:TEMP\crate-base.tar")
  }

  Write-Log I archive inject "base+tool+$agent tarballs"
  $wslSetup = & $wslSrc "$projectRoot\bin\setup-tools.sh"
  $wslArchives = @()
  foreach ($archive in $baseArchive, $toolArchive, $agentArchive) {
    $wslArchives += & $wslSrc $archive
  }
  Invoke-Must wsl -d $distroName -u root -- env AGENT_BIN_DIR=/home/agent/.local/bin AGENT_LIB_DIR=/home/agent/.local/lib sh $wslSetup --log-level $LogLevel @wslArchives

  # Bake setup-system-mounts.sh into the distro at a stable path.
  # Must happen here (while /mnt/c is still automounted) because
  # wsl.conf below disables automount.
  $wslSetupSys = & $wslSrc "$projectRoot\bin\setup-system-mounts.sh"
  Invoke-Must wsl -d $distroName -u root -- cp $wslSetupSys /usr/local/libexec/crate/setup-system-mounts.sh
  Invoke-Must wsl -d $distroName -u root -- chmod +x /usr/local/libexec/crate/setup-system-mounts.sh

  $wslConf = & $wslSrc "$projectRoot\config\wsl.conf"
  Invoke-Must wsl -d $distroName -u root -- cp $wslConf /etc/wsl.conf
  wsl --terminate $distroName 2>$null

  # ── Mount and configure ──

  # Mount the Windows workdir into the distro via drvfs with metadata.
  #
  # metadata/uid/gid/umask/fmask are required for Linux mode bits and
  # ownership to persist on a Windows-backed mount (the default drvfs
  # mount ignores chmod/chown silently, which makes codex's
  # set_permissions(0o600) calls return EPERM and crash TUI bootstrap).
  # uid/gid match the agent user pinned by the Containerfile (24368).
  Write-Log I distro mount "$($PWD.Path) -> /var/workdir"
  $winWorkdir = $PWD.Path
  Invoke-Must wsl -d $distroName -u root -- sh -c "
    mkdir -p /var/workdir &&
    mount -t drvfs -o metadata,uid=24368,gid=24368,umask=0022,fmask=0022 '$($winWorkdir.Replace("'", "'\''"))' /var/workdir
  "

  Write-Log I mounts assemble "$crateDir"
  # Encode each list as base64 of NUL-delimited UTF-8 — survives wsl.exe
  # argv marshalling AND lets the receiver split on NUL so filenames
  # containing spaces/quotes/newlines round-trip exactly. Empty list ⇒
  # empty string.
  $toNulB64 = {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    $ms = [System.IO.MemoryStream]::new()
    foreach ($s in $Items) {
      $b = [Text.Encoding]::UTF8.GetBytes($s)
      $ms.Write($b, 0, $b.Length)
      $ms.WriteByte(0)
    }
    [Convert]::ToBase64String($ms.ToArray())
  }
  $cfB64 = & $toNulB64 ([string[]]$configFiles)
  $rfB64 = & $toNulB64 ([string[]]$roFiles)
  $rdB64 = & $toNulB64 ([string[]]$roDirs)
  Invoke-Must wsl -d $distroName -u root -- `
    /usr/local/libexec/crate/setup-system-mounts.sh `
    --log-level $LogLevel `
    --workdir /var/workdir `
    --project-dir $agentProjectDir `
    --target $crateDir `
    --config-files $cfB64 `
    --ro-files $rfB64 `
    --ro-dirs $rdB64

  # ── Launch ──

  $envArgs = ''
  if ($AllowDnf) { $envArgs = 'CRATE_ALLOW_DNF=1' }

  Write-Log I run launch "wsl -d $distroName ($agent)"
  Invoke-Must wsl -d $distroName --cd /var/workdir -- sh -c "
    exec env $envArgs `$HOME/.local/bin/$agentBinary --log-level $LogLevel
  "
}
finally {
  if ($distroName) {
    Write-Log I distro teardown $distroName
    try { wsl --terminate $distroName 2>$null } catch {}
    try { wsl --unregister $distroName 2>$null } catch {}
  }
}
