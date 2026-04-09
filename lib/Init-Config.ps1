# Init-Config.ps1 — resolve config dir and prepare $PWD\.claude for mounting.
# Dot-sourced (not executed).
#
# Sets: $configDir, $configFiles (array of existing file names)
# Also copies files into $PWD\.claude as fallback for scripts that
# cannot do individual file mounts (wsl).

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
      Copy-Item $src ([IO.Path]::Combine($pwdClaude, $f)) -Force
    }
  }
}
