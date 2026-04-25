# Init-Config.ps1 — stage system-scope agent config into the project's
# <projectDir>\.system directory. Dot-sourced (not executed).
#
# Requires (from Agent.ps1): $agentConfigDir, $agentProjectDir,
# $agentManifest.
#
# Sets: $systemDir, $configFiles, $roFiles, $roDirs
#
# Layout (same as lib/init-config.sh):
#
#   $PWD\<projectDir>\.system\
#     ├── ro\      wiped + re-copied each launch
#     ├── rw\      hardlinks to host
#     ├── cr\      runtime-created; persists per project
#     └── .mask\   empty dir — bind source to mask .system from proj scope

$stageRoFile = { param($src, $dest)
  $realInfo = [IO.File]::ResolveLinkTarget($src, $true)
  $real = if ($realInfo) { $realInfo.FullName } else { [IO.Path]::GetFullPath($src) }
  [IO.File]::Copy($real, $dest, $true)
}

$stageRwFile = { param($src, $dest)
  $realInfo = [IO.File]::ResolveLinkTarget($src, $true)
  $real = if ($realInfo) { $realInfo.FullName } else { [IO.Path]::GetFullPath($src) }
  if ([IO.File]::Exists($dest)) { [IO.File]::Delete($dest) }
  try {
    New-Item -ItemType HardLink -Path $dest -Target $real -ErrorAction Stop > $null
  }
  catch {
    Write-Log E config fail "cannot hardlink $real -> $dest (cross-filesystem?); writable config requires same filesystem for host sync"
    throw "cannot hardlink $real -> $dest"
  }
}

$resolveDir = { param($path)
  $info = [IO.Directory]::ResolveLinkTarget($path, $true)
  if ($info) { $info.FullName } else { $path }
}

# Recursive copy used for manifest-declared roDirs. Dereferences
# symlinks so a symlinked skill dir lands as real content in the stage.
$copyRoDir = { param($src, $dest)
  [IO.Directory]::CreateDirectory($dest) > $null
  foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($src)) {
    $name = [IO.Path]::GetFileName($entry)
    $out = [IO.Path]::Combine($dest, $name)
    if ([IO.Directory]::Exists($entry)) {
      $realSub = & $resolveDir $entry
      & $copyRoDir $realSub $out
    }
    else {
      & $stageRoFile $entry $out
    }
  }
}

$initConfigDir = {
  Write-Log I config start "staging $($PWD.Path)\$agentProjectDir\.system"
  if (-not [IO.Directory]::Exists($agentConfigDir)) {
    Write-Log E config fail "$agent config directory not found: $agentConfigDir"
    throw "$agent config directory not found: $agentConfigDir"
  }

  $script:systemDir = [IO.Path]::Combine($PWD.Path, $agentProjectDir, '.system')

  $gitPath = [IO.Path]::Combine($PWD.Path, '.git')
  $gi = [IO.Path]::Combine($PWD.Path, '.gitignore')
  if ([IO.Directory]::Exists($gitPath) -or [IO.File]::Exists($gitPath)) {
    $hasMatch = $false
    if ([IO.File]::Exists($gi)) {
      $pattern = '(?m)^\s*/?' + [regex]::Escape($agentProjectDir) + '(/(\.system)?/?)?\s*$'
      $hasMatch = [IO.File]::ReadAllText($gi) -match $pattern
    }
    if (-not $hasMatch) {
      Write-Log W config gitignore "$gi does not exclude $agentProjectDir/.system/; add a '$agentProjectDir/.system/' entry to keep credentials and session history out of commits"
    }
  }

  $stageRo = [IO.Path]::Combine($script:systemDir, 'ro')
  $stageRw = [IO.Path]::Combine($script:systemDir, 'rw')
  $stageCr = [IO.Path]::Combine($script:systemDir, 'cr')
  $stageMask = [IO.Path]::Combine($script:systemDir, '.mask')

  [IO.Directory]::CreateDirectory($stageRw) > $null
  [IO.Directory]::CreateDirectory($stageCr) > $null
  [IO.Directory]::CreateDirectory($stageMask) > $null

  if ([IO.Directory]::Exists($stageRo)) {
    [IO.Directory]::Delete($stageRo, $true)
  }
  [IO.Directory]::CreateDirectory($stageRo) > $null

  $script:configFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in (Get-AgentList '.files.rw')) {
    $src = [IO.Path]::Combine($agentConfigDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:configFiles.Add($f)
      & $stageRwFile $src ([IO.Path]::Combine($stageRw, $f))
    }
  }

  $script:roFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in (Get-AgentList '.files.ro')) {
    $src = [IO.Path]::Combine($agentConfigDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:roFiles.Add($f)
      & $stageRoFile $src ([IO.Path]::Combine($stageRo, $f))
    }
  }

  $script:roDirs = [Collections.Generic.List[string]]::new()
  foreach ($d in (Get-AgentList '.files.roDirs')) {
    $srcDir = [IO.Path]::Combine($agentConfigDir, $d)
    if (-not [IO.Directory]::Exists($srcDir)) { continue }
    $realSrcDir = & $resolveDir $srcDir
    $script:roDirs.Add($d)
    & $copyRoDir $realSrcDir ([IO.Path]::Combine($stageRo, $d))
  }

  $crPlaceholders = @($script:configFiles) + @($script:roFiles)
  foreach ($f in $crPlaceholders) {
    $p = [IO.Path]::Combine($stageCr, $f)
    if (-not [IO.File]::Exists($p)) { [IO.File]::WriteAllText($p, '') }
  }
  foreach ($d in $script:roDirs) {
    [IO.Directory]::CreateDirectory([IO.Path]::Combine($stageCr, $d)) > $null
  }
  Write-Log I config done "rw=$($script:configFiles.Count) ro-files=$($script:roFiles.Count) ro-dirs=$($script:roDirs.Count)"
}
