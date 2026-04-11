# Init-Config.ps1 — resolve config dir and prepare $PWD\.claude for mounting.
# Dot-sourced (not executed).
#
# Sets: $configDir, $configFiles (array of existing file names)
# Hardlinks files into $PWD\.claude after resolving any symlink chains.
#
# Claude Code uses atomic file replacement (write temp + rename), which
# would break hardlinks by creating a new inode. All backends prevent
# this by making each config file a bind mount point — rename() and
# unlink() fail with EBUSY, forcing in-place writes that preserve the
# shared inode.
#
# Container backends: podman -v mounts each file individually.
# VM/WSL backends: launcher scripts run mount --bind inside the sandbox.

$initConfigDir = {
  $script:configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($HOME, '.claude') }
  $pwdClaude = [IO.Path]::Combine($PWD.Path, '.claude')
  [IO.Directory]::CreateDirectory($script:configDir) > $null
  [IO.Directory]::CreateDirectory($pwdClaude) > $null

  $script:configFiles = @()
  foreach ($f in '.credentials.json', 'settings.json', '.claude.json') {
    $src = [IO.Path]::Combine($script:configDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:configFiles += $f
      $realInfo = [IO.File]::ResolveLinkTarget($src, $true)
      $real = if ($realInfo) { $realInfo.FullName } else { (Resolve-Path $src).Path }
      $dest = [IO.Path]::Combine($pwdClaude, $f)
      if ([IO.File]::Exists($dest)) { [IO.File]::Delete($dest) }
      New-Item -ItemType HardLink -Path $dest -Target $real > $null
    }
  }
}
