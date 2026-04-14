# Tools.ps1 — tool archive build system
# Dot-sourced (not executed). Requires: $projectRoot

$sha256 = {
  [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
  ).Replace('-', '').ToLower()
}

# Structured logging is provided by Write-Log in lib/Log.ps1, dot-sourced
# from Init-Launcher.ps1.

$http = [Net.Http.HttpClient]::new()
$http.DefaultRequestHeaders.UserAgent.ParseAdd('claude-code-sandbox/1.0')

# ── Tool archive system ──

$cacheDir = if ($env:XDG_CACHE_HOME) { "$env:XDG_CACHE_HOME\claude-code-sandbox" } else { "$HOME\.cache\claude-code-sandbox" }
$toolsDir = "$cacheDir\tools"

$detectArch = {
  $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  switch ($osArch) {
    'X64' {
      $script:archNode = 'x64'
      $script:archRg = 'x86_64-unknown-linux-musl'
      $script:archMicro = 'linux64-static'
      $script:archUv = 'x86_64-unknown-linux-musl'
      $script:archPnpm = 'linux-x64'
      $script:archClaude = 'linux-x64'
    }
    'Arm64' {
      $script:archNode = 'arm64'
      $script:archRg = 'aarch64-unknown-linux-gnu'
      $script:archMicro = 'linux-arm64'
      $script:archUv = 'aarch64-unknown-linux-musl'
      $script:archPnpm = 'linux-arm64'
      $script:archClaude = 'linux-arm64'
    }
    default {
      Write-Log E tools fail "unsupported architecture: $osArch"
      throw "unsupported architecture: $osArch"
    }
  }
}

$fetchToolVersions = {
  $nodeTask = $http.GetStringAsync('https://nodejs.org/dist/index.json')
  $rgTask = $http.GetStringAsync('https://api.github.com/repos/BurntSushi/ripgrep/releases/latest')
  $microTask = $http.GetStringAsync('https://api.github.com/repos/zyedidia/micro/releases/latest')
  $pnpmTask = $http.GetStringAsync('https://registry.npmjs.org/pnpm/latest')
  $uvTask = $http.GetStringAsync('https://pypi.org/pypi/uv/json')
  $claudeTask = $http.GetStringAsync('https://registry.npmjs.org/@anthropic-ai/claude-code/latest')
  [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $pnpmTask, $uvTask, $claudeTask)

  $nodeJson = [Text.Json.JsonDocument]::Parse($nodeTask.Result)
  $rgJson = [Text.Json.JsonDocument]::Parse($rgTask.Result)
  $microJson = [Text.Json.JsonDocument]::Parse($microTask.Result)
  $pnpmJson = [Text.Json.JsonDocument]::Parse($pnpmTask.Result)
  $uvJson = [Text.Json.JsonDocument]::Parse($uvTask.Result)
  $claudeJson = [Text.Json.JsonDocument]::Parse($claudeTask.Result)

  # Node LTS: find first entry where lts is not false
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
  $script:claudeVer = $claudeJson.RootElement.GetProperty('version').GetString()

  $nodeJson.Dispose(); $rgJson.Dispose(); $microJson.Dispose()
  $pnpmJson.Dispose(); $uvJson.Dispose(); $claudeJson.Dispose()
}

# Verify a cached tar.xz: present, non-empty, and decodable.
# `tar -tJf` walks both the xz stream and the tar structure, so it
# catches truncation from interrupted previous runs / partial
# downloads / disk corruption.
$archiveOk = { param($path)
  if (-not [IO.File]::Exists($path)) { return $false }
  if ((Get-Item $path).Length -eq 0) { return $false }
  & tar -tJf $path *> $null
  return ($LASTEXITCODE -eq 0)
}

$resolveArchive = { param($tier, $prefix)
  # Note: don't name this $matches — that's a PowerShell automatic
  # variable populated by -match / -replace.
  $cached = @(Get-ChildItem "$toolsDir\${tier}-${prefix}*.tar.xz" -ErrorAction SilentlyContinue)
  if ($cached.Count -eq 0) {
    Write-Log E "tools.$tier" fail "no cached archive matching hash '$prefix'"
    throw "no cached $tier archive matching hash '$prefix'"
  }
  if ($cached.Count -gt 1) {
    Write-Log E "tools.$tier" fail "ambiguous hash prefix '$prefix' matches multiple archives"
    throw "ambiguous $tier hash prefix '$prefix'"
  }
  $cached[0].FullName
}

$buildToolArchives = {
  [IO.Directory]::CreateDirectory($toolsDir) > $null
  # Sweep stale .partial.* archives left by interrupted previous runs
  # (we build to a temp name and atomic-rename on success, so a
  # partial archive at the final path should never exist — but the
  # temp file leaks on Ctrl-C and needs collecting).
  Get-ChildItem "$toolsDir\*.partial.*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

  # ── Tier 1: Base ──
  if ($optBaseHash) {
    $script:baseArchive = & $resolveArchive 'base' $optBaseHash
    if (-not (& $archiveOk $baseArchive)) {
      Write-Log E tools.base fail "pinned archive is corrupt: $(Split-Path -Leaf $baseArchive)"
      throw "pinned base archive is corrupt"
    }
    Write-Log I tools.base cache-pin (Split-Path -Leaf $baseArchive)
  }
  else {
    if (-not $script:nodeVer) { . $fetchToolVersions }
    # Normalize line endings: the .sh launcher reads this file via raw
    # `cat`, so a CRLF checkout on Windows would otherwise produce a
    # different cache hash for the same canonical source.
    $wrapperSrc = ([IO.File]::ReadAllText("$projectRoot\bin\claude-wrapper.sh")).Replace("`r`n", "`n")
    $baseHash = & $sha256 "base-node:$nodeVer-rg:$rgVer-micro:$microVer-$wrapperSrc"
    $script:baseArchive = "$toolsDir\base-$baseHash.tar.xz"
    if ((-not $forcePull) -and (& $archiveOk $baseArchive)) {
      Write-Log I tools.base cache-hit (Split-Path -Leaf $baseArchive)
    }
    else {
      if ([IO.File]::Exists($baseArchive) -and -not $forcePull) {
        Write-Log W tools.base rebuild "cached archive corrupt; rebuilding"
        Remove-Item $baseArchive -Force
      }
      Write-Log I tools.base downloading "node $nodeVer, ripgrep $rgVer, micro $microVer"
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        # Download node, rg, micro — start all async, then extract sequentially
        $nodeUrl = "https://nodejs.org/dist/v${nodeVer}/node-v${nodeVer}-linux-${archNode}.tar.xz"
        $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/${rgVer}/ripgrep-${rgVer}-${archRg}.tar.gz"
        $microUrl = "https://github.com/zyedidia/micro/releases/download/v${microVer}/micro-${microVer}-${archMicro}.tar.gz"
        $nodeTask = $http.GetByteArrayAsync($nodeUrl)
        $rgTask = $http.GetByteArrayAsync($rgUrl)
        $microTask = $http.GetByteArrayAsync($microUrl)
        [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask)

        # Write and extract each
        $nodeTmp = "$tmpDir\_node.tar.xz"; [IO.File]::WriteAllBytes($nodeTmp, $nodeTask.Result)
        tar -xJf $nodeTmp -C $tmpDir --strip-components=2 "node-v${nodeVer}-linux-${archNode}/bin/node"
        Remove-Item $nodeTmp

        $rgTmp = "$tmpDir\_rg.tar.gz"; [IO.File]::WriteAllBytes($rgTmp, $rgTask.Result)
        tar -xzf $rgTmp -C $tmpDir --strip-components=1 "ripgrep-${rgVer}-${archRg}/rg"
        Remove-Item $rgTmp

        $microTmp = "$tmpDir\_micro.tar.gz"; [IO.File]::WriteAllBytes($microTmp, $microTask.Result)
        tar -xzf $microTmp -C $tmpDir --strip-components=1 "micro-${microVer}/micro"
        Remove-Item $microTmp

        Copy-Item "$projectRoot\bin\claude-wrapper.sh" "$tmpDir\claude-wrapper"
        Write-Log I tools.base packing (Split-Path -Leaf $baseArchive)
        # Build to a temp path and atomic-rename on success. If the
        # process is killed mid-tar, the partial file sits at the
        # .partial path and gets swept on the next run; the final
        # archive path is never partially written.
        $baseTmp = "$baseArchive.partial.$PID"
        tar -cJf $baseTmp -C $tmpDir node rg micro claude-wrapper
        Move-Item -Force $baseTmp $baseArchive
        Write-Log I tools.base cached (Split-Path -Leaf $baseArchive)
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  # ── Tier 2: Tool ──
  if ($optToolHash) {
    $script:toolArchive = & $resolveArchive 'tool' $optToolHash
    if (-not (& $archiveOk $toolArchive)) {
      Write-Log E tools.tool fail "pinned archive is corrupt: $(Split-Path -Leaf $toolArchive)"
      throw "pinned tool archive is corrupt"
    }
    Write-Log I tools.tool cache-pin (Split-Path -Leaf $toolArchive)
  }
  else {
    if (-not $script:pnpmVer) { . $fetchToolVersions }
    $toolHash = & $sha256 "tool-pnpm:$pnpmVer-uv:$uvVer"
    $script:toolArchive = "$toolsDir\tool-$toolHash.tar.xz"
    if ((-not $forcePull) -and (& $archiveOk $toolArchive)) {
      Write-Log I tools.tool cache-hit (Split-Path -Leaf $toolArchive)
    }
    else {
      if ([IO.File]::Exists($toolArchive) -and -not $forcePull) {
        Write-Log W tools.tool rebuild "cached archive corrupt; rebuilding"
        Remove-Item $toolArchive -Force
      }
      Write-Log I tools.tool downloading "pnpm $pnpmVer, uv $uvVer"
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        $pnpmTask = $http.GetByteArrayAsync("https://github.com/pnpm/pnpm/releases/download/v${pnpmVer}/pnpm-${archPnpm}")
        $uvTask = $http.GetByteArrayAsync("https://github.com/astral-sh/uv/releases/download/${uvVer}/uv-${archUv}.tar.gz")
        [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask)

        [IO.File]::WriteAllBytes("$tmpDir\pnpm", $pnpmTask.Result)
        $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
        tar -xzf $uvTmp -C $tmpDir --strip-components=1
        Remove-Item $uvTmp

        Write-Log I tools.tool packing (Split-Path -Leaf $toolArchive)
        $toolTmp = "$toolArchive.partial.$PID"
        tar -cJf $toolTmp -C $tmpDir pnpm uv uvx
        Move-Item -Force $toolTmp $toolArchive
        Write-Log I tools.tool cached (Split-Path -Leaf $toolArchive)
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  # ── Tier 3: Claude ──
  if ($optClaudeHash) {
    $script:claudeArchive = & $resolveArchive 'claude' $optClaudeHash
    if (-not (& $archiveOk $claudeArchive)) {
      Write-Log E tools.claude fail "pinned archive is corrupt: $(Split-Path -Leaf $claudeArchive)"
      throw "pinned claude archive is corrupt"
    }
    Write-Log I tools.claude cache-pin (Split-Path -Leaf $claudeArchive)
  }
  else {
    if (-not $script:claudeVer) { . $fetchToolVersions }
    $claudeHash = & $sha256 "claude-$claudeVer"
    $script:claudeArchive = "$toolsDir\claude-$claudeHash.tar.xz"
    if ((-not $forcePull) -and (& $archiveOk $claudeArchive)) {
      Write-Log I tools.claude cache-hit (Split-Path -Leaf $claudeArchive)
    }
    else {
      if ([IO.File]::Exists($claudeArchive) -and -not $forcePull) {
        Write-Log W tools.claude rebuild "cached archive corrupt; rebuilding"
        Remove-Item $claudeArchive -Force
      }
      Write-Log I tools.claude downloading "claude $claudeVer"
      $gcsBucket = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
      $tmpDir = Join-Path ([IO.Path]::GetTempPath()) "claude-build-$(Get-Random)"
      [IO.Directory]::CreateDirectory($tmpDir) > $null
      try {
        $claudeBytes = $http.GetByteArrayAsync("$gcsBucket/$claudeVer/$archClaude/claude").Result
        [IO.File]::WriteAllBytes("$tmpDir\claude", $claudeBytes)
        Write-Log I tools.claude packing (Split-Path -Leaf $claudeArchive)
        $claudeTmp = "$claudeArchive.partial.$PID"
        tar -cJf $claudeTmp -C $tmpDir claude
        Move-Item -Force $claudeTmp $claudeArchive
        Write-Log I tools.claude cached (Split-Path -Leaf $claudeArchive)
      }
      finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
}
