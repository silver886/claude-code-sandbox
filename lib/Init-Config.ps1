# Init-Config.ps1 — stage system-scope Claude config into the project's
# .claude/.system directory. Dot-sourced (not executed).
#
# Sets: $configDir, $systemDir, $configFiles, $roFiles, $roDirs
#
# See lib/init-config.sh for the full layout rationale. Brief summary:
#
#   $PWD\.claude\.system\
#     ├── ro\      — wiped + re-copied each launch (CLAUDE.md, rules\, skills\, …)
#     ├── rw\      — hardlinks each launch (.credentials.json, settings.json, .claude.json)
#     ├── cr\      — created at runtime by Claude; persists per project
#     └── .mask\   — empty dir, used as the bind source to mask .system\
#                    from project scope inside the sandbox
#
# All launchers bind the 3 writable files from $SYSTEM_DIR\rw\<f> into
# /etc/claude-code-sandbox/<f> inside the sandbox; the rw/ hardlinks
# share an inode with $configDir\<f> so writes propagate back to the
# host immediately.

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

# Resolve a directory path through any symlink/junction chain.
$resolveDir = { param($path)
  $info = [IO.Directory]::ResolveLinkTarget($path, $true)
  if ($info) { $info.FullName } else { $path }
}

$initConfigDir = {
  Write-Log I config start "staging $($PWD.Path)\.claude\.system"
  $script:configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($HOME, '.claude') }
  if (-not [IO.Directory]::Exists($script:configDir)) {
    Write-Log E config fail "Claude config directory not found: $script:configDir"
    throw "Claude config directory not found: $script:configDir"
  }

  $script:systemDir = [IO.Path]::Combine($PWD.Path, '.claude', '.system')

  # Warn if the project is a git repo (or worktree) and nothing in
  # .gitignore excludes the system bucket. Credentials and session
  # history live there. Fires both when .gitignore is missing entirely
  # AND when it exists without a matching entry.
  $gitPath = [IO.Path]::Combine($PWD.Path, '.git')
  $gi = [IO.Path]::Combine($PWD.Path, '.gitignore')
  if ([IO.Directory]::Exists($gitPath) -or [IO.File]::Exists($gitPath)) {
    $hasMatch = $false
    if ([IO.File]::Exists($gi)) {
      $hasMatch = [IO.File]::ReadAllText($gi) -match '(?m)^\s*/?\.claude(/(\.system)?/?)?\s*$'
    }
    if (-not $hasMatch) {
      Write-Log W config gitignore "$gi does not exclude .claude/.system/; add a '.claude/.system/' entry to keep credentials and session history out of commits"
    }
  }

  $stageRo = [IO.Path]::Combine($script:systemDir, 'ro')
  $stageRw = [IO.Path]::Combine($script:systemDir, 'rw')
  $stageCr = [IO.Path]::Combine($script:systemDir, 'cr')
  $stageMask = [IO.Path]::Combine($script:systemDir, '.mask')

  [IO.Directory]::CreateDirectory($stageRw) > $null
  [IO.Directory]::CreateDirectory($stageCr) > $null
  [IO.Directory]::CreateDirectory($stageMask) > $null

  # Wipe + re-create ro/ so upstream deletions propagate and any
  # in-session tampering on copies is undone.
  if ([IO.Directory]::Exists($stageRo)) {
    [IO.Directory]::Delete($stageRo, $true)
  }
  [IO.Directory]::CreateDirectory($stageRo) > $null

  # Writable files → rw/ (hardlinks to host).
  # Use List[string] rather than @() + `+=`; `+=` on PS arrays is O(n)
  # (the whole array is reallocated each time) so a `+=` loop is O(n²).
  $script:configFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in '.credentials.json', 'settings.json', '.claude.json') {
    $src = [IO.Path]::Combine($script:configDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:configFiles.Add($f)
      & $stageRwFile $src ([IO.Path]::Combine($stageRw, $f))
    }
  }

  # Read-only single files → ro/
  $script:roFiles = [Collections.Generic.List[string]]::new()
  foreach ($f in 'CLAUDE.md', 'keybindings.json') {
    $src = [IO.Path]::Combine($script:configDir, $f)
    if ([IO.File]::Exists($src)) {
      $script:roFiles.Add($f)
      & $stageRoFile $src ([IO.Path]::Combine($stageRo, $f))
    }
  }

  # Read-only directories (flat) → ro/<d>/
  $script:roDirs = [Collections.Generic.List[string]]::new()
  foreach ($d in 'rules', 'commands', 'agents', 'output-styles') {
    $srcDir = [IO.Path]::Combine($script:configDir, $d)
    if (-not [IO.Directory]::Exists($srcDir)) { continue }
    $realSrcDir = & $resolveDir $srcDir
    $script:roDirs.Add($d)
    $destDir = [IO.Path]::Combine($stageRo, $d)
    [IO.Directory]::CreateDirectory($destDir) > $null
    foreach ($file in [IO.Directory]::EnumerateFiles($realSrcDir)) {
      & $stageRoFile $file ([IO.Path]::Combine($destDir, [IO.Path]::GetFileName($file)))
    }
  }

  # Skills (two-level) → ro/skills/<name>/
  $skillsDir = [IO.Path]::Combine($script:configDir, 'skills')
  if ([IO.Directory]::Exists($skillsDir)) {
    $realSkillsDir = & $resolveDir $skillsDir
    $script:roDirs.Add('skills')
    [IO.Directory]::CreateDirectory([IO.Path]::Combine($stageRo, 'skills')) > $null
    foreach ($skillDir in [IO.Directory]::EnumerateDirectories($realSkillsDir)) {
      $name = [IO.Path]::GetFileName($skillDir)
      $realSkillDir = & $resolveDir $skillDir
      $destSkill = [IO.Path]::Combine($stageRo, 'skills', $name)
      [IO.Directory]::CreateDirectory($destSkill) > $null
      foreach ($file in [IO.Directory]::EnumerateFiles($realSkillDir)) {
        & $stageRoFile $file ([IO.Path]::Combine($destSkill, [IO.Path]::GetFileName($file)))
      }
    }
  }

  # cr/ placeholders — created AFTER discovery so we only place files /
  # dirs that the launcher will actually bind-mount on top of. Without
  # these, podman would auto-create empty placeholder files inside cr/
  # on the host when processing the nested -v flags. See lib/init-config.sh
  # for the full rationale.
  foreach ($f in [string[]]$script:configFiles + [string[]]$script:roFiles) {
    $p = [IO.Path]::Combine($stageCr, $f)
    if (-not [IO.File]::Exists($p)) { [IO.File]::WriteAllText($p, '') }
  }
  foreach ($d in $script:roDirs) {
    [IO.Directory]::CreateDirectory([IO.Path]::Combine($stageCr, $d)) > $null
  }
  Write-Log I config done "rw=$($script:configFiles.Count) ro-files=$($script:roFiles.Count) ro-dirs=$($script:roDirs.Count)"
}
