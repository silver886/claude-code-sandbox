# Tools.ps1 — tool archive build system (multi-agent).
# Dot-sourced (not executed). Requires: $projectRoot, $agent,
# $agentManifest (from Agent.ps1).

$sha256 = {
  [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
  ).Replace('-', '').ToLower()
}

$md5 = {
  [BitConverter]::ToString(
    [Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
  ).Replace('-', '').ToLower()
}

$http = [Net.Http.HttpClient]::new()
$http.DefaultRequestHeaders.UserAgent.ParseAdd('agent-sandbox/1.0')

# ── Tool archive system ──

$cacheDir = if ($env:XDG_CACHE_HOME) { "$env:XDG_CACHE_HOME\agent-sandbox" } else { "$HOME\.cache\agent-sandbox" }
$toolsDir = "$cacheDir\tools"

# Distinct values grouped by the arch-suffix convention each tool uses.
# Only genuine primitives are case-branched; everything else is derived:
#   $arch        — Node.js / pnpm suffix / npm platform sub-pkg {arch}
#                    (x64 on X64, arm64 on Arm64)
#   $archGnu     — prefix of Rust-style triples
#                    (x86_64 on X64, aarch64 on Arm64)
#   $archMicro   — micro's release-asset suffix — unrelated schemes
#                    (linux64-static on X64, linux-arm64 on Arm64)
#   $archRg      — ripgrep's triple — musl on X64, gnu on Arm64
#                    (BurntSushi/ripgrep doesn't ship musl arm64)
#   $archTriple  — full musl triple, used by uv and Codex {triple}
$detectArch = {
  $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  switch ($osArch) {
    'X64' {
      $script:arch = 'x64'
      $script:archGnu = 'x86_64'
      $script:archMicro = 'linux64-static'
      $rgLibc = 'musl'
    }
    'Arm64' {
      $script:arch = 'arm64'
      $script:archGnu = 'aarch64'
      $script:archMicro = 'linux-arm64'
      $rgLibc = 'gnu'
    }
    default {
      Write-Log E tools fail "unsupported architecture: $osArch"
      throw "unsupported architecture: $osArch"
    }
  }
  $script:archTriple = "$($script:archGnu)-unknown-linux-musl"
  $script:archRg = "$($script:archGnu)-unknown-linux-$rgLibc"
}

# Substitute {arch}, {triple}, {version} in a template string.
$substTokens = { param($template, $version)
  $template.Replace('{arch}', $script:arch).
  Replace('{triple}', $script:archTriple).
  Replace('{version}', $version)
}

$fetchSharedVersions = {
  $nodeTask = $http.GetStringAsync('https://nodejs.org/dist/index.json')
  $rgTask = $http.GetStringAsync('https://api.github.com/repos/BurntSushi/ripgrep/releases/latest')
  $microTask = $http.GetStringAsync('https://api.github.com/repos/zyedidia/micro/releases/latest')
  $pnpmTask = $http.GetStringAsync('https://registry.npmjs.org/pnpm/latest')
  $uvTask = $http.GetStringAsync('https://pypi.org/pypi/uv/json')
  [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $pnpmTask, $uvTask)

  $nodeJson = [Text.Json.JsonDocument]::Parse($nodeTask.Result)
  $rgJson = [Text.Json.JsonDocument]::Parse($rgTask.Result)
  $microJson = [Text.Json.JsonDocument]::Parse($microTask.Result)
  $pnpmJson = [Text.Json.JsonDocument]::Parse($pnpmTask.Result)
  $uvJson = [Text.Json.JsonDocument]::Parse($uvTask.Result)

  $script:nodeVer = $null
  foreach ($el in $nodeJson.RootElement.EnumerateArray()) {
    $lts = $el.GetProperty('lts')
    if ($lts.ValueKind -ne [Text.Json.JsonValueKind]::False) {
      $script:nodeVer = $el.GetProperty('version').GetString().TrimStart('v')
      break
    }
  }
  $script:rgVer = $rgJson.RootElement.GetProperty('tag_name').GetString()
  $script:microVer = $microJson.RootElement.GetProperty('tag_name').GetString().TrimStart('v')
  $script:pnpmVer = $pnpmJson.RootElement.GetProperty('version').GetString()
  $script:uvVer = $uvJson.RootElement.GetProperty('info').GetProperty('version').GetString()

  $nodeJson.Dispose(); $rgJson.Dispose(); $microJson.Dispose()
  $pnpmJson.Dispose(); $uvJson.Dispose()
}

$fetchAgentVersion = {
  $pkg = Get-AgentField '.executable.versionPackage'
  $json = $http.GetStringAsync("https://registry.npmjs.org/$pkg/latest").Result
  $doc = [Text.Json.JsonDocument]::Parse($json)
  $script:agentVer = $doc.RootElement.GetProperty('version').GetString()
  $doc.Dispose()
  if (-not $script:agentVer) {
    Write-Log E tools fail "failed to fetch version for $pkg"
    throw "failed to fetch agent version"
  }
}

$resolveArchive = { param($tier, $prefix)
  $cached = $null
  if ([IO.Directory]::Exists($toolsDir)) {
    $cached = [IO.Directory]::GetFiles($toolsDir, "${tier}-${prefix}*.tar.xz")
  }
  if (-not $cached -or $cached.Length -eq 0) {
    Write-Log E "tools.$tier" fail "no cached archive matching hash '$prefix'"
    throw "no cached $tier archive matching hash '$prefix'"
  }
  if ($cached.Length -gt 1) {
    Write-Log E "tools.$tier" fail "ambiguous hash prefix '$prefix' matches multiple archives"
    throw "ambiguous $tier hash prefix '$prefix'"
  }
  $cached[0]
}

# ── Tier builder ──
#
# Shared script block that runs inside each Start-ThreadJob runspace.
# Thread-job runspaces don't inherit the parent's script scope, so
# everything is passed as explicit params. For the agent tier, the
# caller passes prebuilt inputs (tarball URL, bin/entry path, manifest
# shell-script contents, wrapper source) instead of parsing the manifest
# inside the job.

$tierBuilder = {
  param($logLevel, $projectRoot, $tier, $archive, $optHash, $forcePull, $vars)
  # ThreadJob runspaces don't inherit the parent's preference variables,
  # so .NET method exceptions would default to non-terminating. Force
  # 'Stop' here so any failure escapes the job instead of being swallowed.
  $ErrorActionPreference = 'Stop'
  $script:LogLevel = $logLevel
  . "$projectRoot\lib\Log.ps1"
  $stage = "tools.$tier"

  # $ErrorActionPreference does NOT cover native command exit codes —
  # `tar` and friends keep going on non-zero. Wrap them so a failed
  # extract/pack throws instead of producing a silently-bad archive.
  # Slice safely: $args[1..0] would reverse-range when only the cmd is
  # passed, so guard with the count.
  $mustNative = {
    $cmd = $args[0]
    $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
    & $cmd @rest
    if ($LASTEXITCODE -ne 0) {
      throw "$stage`: $cmd failed (exit $LASTEXITCODE): $($args -join ' ')"
    }
  }

  $archiveOk = { param($p)
    if (-not [IO.File]::Exists($p)) { return $false }
    if ([IO.FileInfo]::new($p).Length -eq 0) { return $false }
    & tar -tf $p *> $null
    return ($LASTEXITCODE -eq 0)
  }

  if ($optHash) {
    if (-not (& $archiveOk $archive)) {
      Write-Log E $stage fail "pinned archive is corrupt: $([IO.Path]::GetFileName($archive))"
      throw "pinned $tier archive is corrupt"
    }
    Write-Log I $stage cache-pin ([IO.Path]::GetFileName($archive))
    return
  }
  if ((-not $forcePull) -and (& $archiveOk $archive)) {
    Write-Log I $stage cache-hit ([IO.Path]::GetFileName($archive))
    return
  }
  if ([IO.File]::Exists($archive) -and -not $forcePull) {
    Write-Log W $stage rebuild "cached archive corrupt; rebuilding"
    [IO.File]::Delete($archive)
  }

  $h = [Net.Http.HttpClient]::new()
  $h.DefaultRequestHeaders.UserAgent.ParseAdd('agent-sandbox/1.0')
  $tmpDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "agent-build-$(Get-Random)")
  [IO.Directory]::CreateDirectory($tmpDir) > $null
  try {
    $packInputs = $null
    switch ($vars.kind) {
      'base' {
        Write-Log I $stage downloading "node $($vars.nodeVer), ripgrep $($vars.rgVer), micro $($vars.microVer)"
        $nodeUrl = "https://nodejs.org/dist/v$($vars.nodeVer)/node-v$($vars.nodeVer)-linux-$($vars.arch).tar.xz"
        $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$($vars.rgVer)/ripgrep-$($vars.rgVer)-$($vars.archRg).tar.gz"
        $microUrl = "https://github.com/zyedidia/micro/releases/download/v$($vars.microVer)/micro-$($vars.microVer)-$($vars.archMicro).tar.gz"
        $nodeTask = $h.GetByteArrayAsync($nodeUrl)
        $rgTask = $h.GetByteArrayAsync($rgUrl)
        $microTask = $h.GetByteArrayAsync($microUrl)
        [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask)

        $nodeTmp = "$tmpDir\_node.tar.xz"; [IO.File]::WriteAllBytes($nodeTmp, $nodeTask.Result)
        & $mustNative tar -xJf $nodeTmp -C $tmpDir --strip-components=2 "node-v$($vars.nodeVer)-linux-$($vars.arch)/bin/node"
        [IO.File]::Delete($nodeTmp)

        $rgTmp = "$tmpDir\_rg.tar.gz"; [IO.File]::WriteAllBytes($rgTmp, $rgTask.Result)
        & $mustNative tar -xzf $rgTmp -C $tmpDir --strip-components=1 "ripgrep-$($vars.rgVer)-$($vars.archRg)/rg"
        [IO.File]::Delete($rgTmp)

        $microTmp = "$tmpDir\_micro.tar.gz"; [IO.File]::WriteAllBytes($microTmp, $microTask.Result)
        & $mustNative tar -xzf $microTmp -C $tmpDir --strip-components=1 "micro-$($vars.microVer)/micro"
        [IO.File]::Delete($microTmp)

        $packInputs = @('node', 'rg', 'micro')
      }
      'tool' {
        Write-Log I $stage downloading "pnpm $($vars.pnpmVer), uv $($vars.uvVer)"
        $pnpmTask = $h.GetByteArrayAsync("https://github.com/pnpm/pnpm/releases/download/v$($vars.pnpmVer)/pnpm-linux-$($vars.arch)")
        $uvTask = $h.GetByteArrayAsync("https://github.com/astral-sh/uv/releases/download/$($vars.uvVer)/uv-$($vars.archTriple).tar.gz")
        [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask)

        [IO.File]::WriteAllBytes("$tmpDir\pnpm", $pnpmTask.Result)
        $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
        & $mustNative tar -xzf $uvTmp -C $tmpDir --strip-components=1
        [IO.File]::Delete($uvTmp)
        $packInputs = @('pnpm', 'uv', 'uvx')
      }
      'agent' {
        Write-Log I $stage downloading "$($vars.agentName) $($vars.agentVer) ($($vars.execType))"
        $tarTmp = "$tmpDir\_agent.tgz"
        $extractDir = "$tmpDir\_extract"
        [IO.Directory]::CreateDirectory($extractDir) > $null
        [IO.File]::WriteAllBytes($tarTmp, $h.GetByteArrayAsync($vars.tarballUrl).Result)
        & $mustNative tar -xzf $tarTmp -C $extractDir
        [IO.File]::Delete($tarTmp)

        $binary = $vars.agentBinary
        switch ($vars.execType) {
          'platform-binary' {
            $binSrc = [IO.Path]::Combine($extractDir, $vars.binPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not [IO.File]::Exists($binSrc)) {
              Write-Log E $stage fail "binary not found in tarball: $($vars.binPath)"
              throw "binary not found in tarball"
            }
            [IO.File]::Copy($binSrc, "$tmpDir\$binary-bin", $true)
            $packInputs = @($binary, 'agent-manifest.sh', "$binary-bin")
          }
          'node-bundle' {
            $pkgSrc = [IO.Path]::Combine($extractDir, 'package')
            if (-not [IO.Directory]::Exists($pkgSrc)) {
              Write-Log E $stage fail "node bundle has no 'package/' dir"
              throw "node bundle has no package/ dir"
            }
            $pkgName = "$binary-pkg"
            [IO.Directory]::Move($pkgSrc, "$tmpDir\$pkgName")
            $entryRel = $vars.entryPath
            if ($entryRel.StartsWith('package/')) { $entryRel = $entryRel.Substring('package/'.Length) }
            $shim = "#!/usr/bin/env sh`nexec node `"`$HOME/.local/lib/$pkgName/$entryRel`" `"`$@`"`n"
            [IO.File]::WriteAllText("$tmpDir\$binary-bin", $shim)
            $packInputs = @($binary, 'agent-manifest.sh', "$binary-bin", $pkgName)
          }
          default { throw "unknown executable.type: $($vars.execType)" }
        }

        # Wrapper goes in under the agent command name (regular file,
        # not a symlink) — same choice as lib/tools.sh. Keeps behavior
        # identical across Linux/WSL/Windows host filesystems.
        [IO.File]::WriteAllText("$tmpDir\agent-manifest.sh", $vars.manifestShContents)
        [IO.File]::WriteAllText("$tmpDir\$binary", $vars.wrapperSrc)

        [IO.Directory]::Delete($extractDir, $true)
      }
      default { throw "unknown tier kind: $($vars.kind)" }
    }

    Write-Log I $stage packing ([IO.Path]::GetFileName($archive))
    $tmp = "$archive.partial.$PID"
    # Three-tier strategy (mirrors lib/tools.sh._detect_pack_xz_mode):
    #   1. external xz on PATH: pipe `tar -cf - ... | xz -0 -T0 -c`
    #   2. bsdtar (libarchive): `--xz --options 'xz:compression-level=0,xz:threads=0'`
    #   3. fallback: `tar --xz` with default level/threads (slower, larger)
    # Windows ships bsdtar with liblzma — path 2 is the common case.
    # Windows ships bsdtar (libarchive), where -I is a synonym for -T
    # (--files-from), not --use-compress-program as in GNU tar. Use the
    # native --xz flag or the explicit xz-pipe path instead.
    $xzCmd = Get-Command xz -ErrorAction SilentlyContinue
    if ($xzCmd) {
      # Pipe via System.Diagnostics.Process — PowerShell native pipelines
      # can corrupt binary data. CopyToAsync on both ends avoids deadlocks
      # when the kernel pipe buffer fills before xz reads.
      $tarPsi = [Diagnostics.ProcessStartInfo]::new('tar')
      foreach ($a in @('-cf', '-', '-C', $tmpDir) + $packInputs) { [void]$tarPsi.ArgumentList.Add($a) }
      $tarPsi.RedirectStandardOutput = $true
      $tarPsi.UseShellExecute = $false
      $xzPsi = [Diagnostics.ProcessStartInfo]::new($xzCmd.Source)
      foreach ($a in @('-0', '-T0', '-c')) { [void]$xzPsi.ArgumentList.Add($a) }
      $xzPsi.RedirectStandardInput = $true
      $xzPsi.RedirectStandardOutput = $true
      $xzPsi.UseShellExecute = $false

      $tarProc = [Diagnostics.Process]::Start($tarPsi)
      $xzProc = [Diagnostics.Process]::Start($xzPsi)
      $outFs = [IO.File]::Create($tmp)
      try {
        $copyIn = $tarProc.StandardOutput.BaseStream.CopyToAsync($xzProc.StandardInput.BaseStream)
        $copyOut = $xzProc.StandardOutput.BaseStream.CopyToAsync($outFs)
        $copyIn.Wait()
        $xzProc.StandardInput.Close()
        $copyOut.Wait()
        $tarProc.WaitForExit()
        $xzProc.WaitForExit()
      }
      finally { $outFs.Close() }
      if ($tarProc.ExitCode -ne 0) { throw "$stage`: tar failed (exit $($tarProc.ExitCode))" }
      if ($xzProc.ExitCode -ne 0) { throw "$stage`: xz failed (exit $($xzProc.ExitCode))" }
    }
    elseif ((& tar --version 2>&1 | Select-Object -First 1) -match 'bsdtar') {
      & $mustNative tar --xz --options 'xz:compression-level=0,xz:threads=0' -cf $tmp -C $tmpDir @packInputs
    }
    else {
      Write-Log W $stage fallback "no xz CLI and tar is not bsdtar; using tar --xz defaults (slower, larger)"
      & $mustNative tar --xz -cf $tmp -C $tmpDir @packInputs
    }
    [IO.File]::Move($tmp, $archive, $true)
    Write-Log I $stage cached ([IO.Path]::GetFileName($archive))
  }
  finally { try { [IO.Directory]::Delete($tmpDir, $true) } catch {} }
}

# Build agent-manifest.sh contents from manifest fields. Mirrors
# _agent_manifest_sh_contents in lib/tools.sh — exact same output so
# tier-3 hashes match across sh/ps1 sides.
$agentManifestShContents = {
  $sb = [Text.StringBuilder]::new(256)
  [void]$sb.Append("AGENT_BINARY=$($script:agentBinary)`n")
  $flags = Get-AgentList '.launch.flags'
  [void]$sb.Append("AGENT_LAUNCH_FLAGS='$($flags -join ' ')'`n")
  # Point the agent's config-dir env var at the system staging path.
  # Skipped for agents whose manifest.configDir.env is empty (Gemini).
  if ($script:agentSandboxEnv) {
    [void]$sb.Append("export $($script:agentSandboxEnv)='$($script:agentSandboxDir)'`n")
  }
  $envKv = Get-AgentKv '.launch.env'
  foreach ($k in $envKv.Keys) {
    [void]$sb.Append("export $k='$($envKv[$k])'`n")
  }
  $sb.ToString()
}

$buildToolArchives = {
  [IO.Directory]::CreateDirectory($toolsDir) > $null
  # GetFiles (not EnumerateFiles) so the file list is materialized up
  # front — deleting during enumeration can invalidate the enumerator
  # and skip entries on some filesystems.
  foreach ($stale in [IO.Directory]::GetFiles($toolsDir, '*.partial.*')) {
    try { [IO.File]::Delete($stale) } catch {}
  }

  $needShared = (-not $optBaseHash) -or (-not $optToolHash)
  $needAgent = -not $optAgentHash
  if ($needShared -and -not $script:nodeVer) { . $fetchSharedVersions }
  if ($needAgent -and -not $script:agentVer) { . $fetchAgentVersion }

  # Archive path resolution.
  if ($optBaseHash) {
    $script:baseArchive = & $resolveArchive 'base' $optBaseHash
  }
  else {
    $baseHash = & $sha256 "base-node:$nodeVer-rg:$rgVer-micro:$microVer"
    $script:baseArchive = "$toolsDir\base-$baseHash.tar.xz"
  }
  if ($optToolHash) {
    $script:toolArchive = & $resolveArchive 'tool' $optToolHash
  }
  else {
    $toolHash = & $sha256 "tool-pnpm:$pnpmVer-uv:$uvVer"
    $script:toolArchive = "$toolsDir\tool-$toolHash.tar.xz"
  }
  # Compute the generated agent-manifest.sh up front — used both in the
  # tier-3 hash seed (so generator changes bust the cache) and passed to
  # the ThreadJob below as the pack input.
  $manifestShContents = & $agentManifestShContents

  if ($optAgentHash) {
    $script:agentArchive = & $resolveArchive $agent $optAgentHash
  }
  else {
    # Include manifest source, generated agent-manifest.sh, and wrapper
    # source in the hash. CRLF → LF so sh-side matches.
    $manifestSrc = ([IO.File]::ReadAllText($agentManifestPath)).Replace("`r`n", "`n")
    $wrapperSrc = ([IO.File]::ReadAllText("$projectRoot\bin\agent-wrapper.sh")).Replace("`r`n", "`n")
    $agentHash = & $sha256 "agent:$agent-ver:$agentVer-arch:$arch-manifest:$manifestSrc-manifest-sh:$manifestShContents-wrapper:$wrapperSrc"
    $script:agentArchive = "$toolsDir\$agent-$agentHash.tar.xz"
  }

  # Prepare agent-tier inputs (parsed on the parent side because
  # manifest objects don't serialize cleanly into thread runspaces).
  $execType = Get-AgentField '.executable.type'
  $tarballUrl = & $substTokens (Get-AgentField '.executable.tarballUrl') $script:agentVer
  $binPath = Get-AgentField '.executable.binPath'
  if ($binPath) { $binPath = & $substTokens $binPath $script:agentVer }
  $entryPath = Get-AgentField '.executable.entryPath'
  if ($entryPath) { $entryPath = & $substTokens $entryPath $script:agentVer }
  $wrapperSrcForPack = ([IO.File]::ReadAllText("$projectRoot\bin\agent-wrapper.sh")).Replace("`r`n", "`n")

  $baseVars = @{
    kind = 'base'
    nodeVer = $script:nodeVer; rgVer = $script:rgVer; microVer = $script:microVer
    arch = $script:arch; archRg = $script:archRg; archMicro = $script:archMicro
  }
  $toolVars = @{
    kind = 'tool'
    pnpmVer = $script:pnpmVer; uvVer = $script:uvVer
    arch = $script:arch; archTriple = $script:archTriple
  }
  $agentVars = @{
    kind = 'agent'
    agentName = $agent; agentBinary = $script:agentBinary
    agentVer = $script:agentVer
    execType = $execType
    tarballUrl = $tarballUrl
    binPath = $binPath; entryPath = $entryPath
    manifestShContents = $manifestShContents
    wrapperSrc = $wrapperSrcForPack
  }
  $jobs = @(
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, 'base', $script:baseArchive, $optBaseHash, $forcePull, $baseVars
    )
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, 'tool', $script:toolArchive, $optToolHash, $forcePull, $toolVars
    )
    Start-ThreadJob -ScriptBlock $tierBuilder -ArgumentList @(
      $script:LogLevel, $projectRoot, $agent, $script:agentArchive, $optAgentHash, $forcePull, $agentVars
    )
  )
  $jobs | Receive-Job -Wait -AutoRemoveJob
}
