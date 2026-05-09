# Tools.ps1 — tool archive build system (multi-agent).
# Dot-sourced (not executed). Requires: $projectRoot, $agent,
# $agentManifest (from Agent.ps1).
#
# Top-level surface (kept minimal — only what crosses into the launcher
# scope): $cacheDir, $detectArch, $buildToolArchives. Every helper, the
# HttpClient, JSON parsing scratch, sha256/SRI helpers, and the tier
# builder live INSIDE $buildToolArchives so dot-sourcing this file
# doesn't pollute the launcher with build-time machinery.

# $cacheDir is read by Init-Launcher's preflight before $detectArch /
# $buildToolArchives are invoked, so it must stay at script scope.
$cacheDir = if ($env:XDG_CACHE_HOME) { "$env:XDG_CACHE_HOME\crate" } else { "$HOME\.cache\crate" }

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

$buildToolArchives = {
  $toolsDir = "$cacheDir\tools"

  # HttpClient for parent-side fetches only (version probes,
  # npm-metadata lookup). Each thread job owns its own — HttpClient
  # never crosses the call boundary. Disposed in the outer try/finally
  # below. UA value comes from $crateUserAgent (lib/Common.ps1) so the
  # 'crate/1.0' literal lives in exactly one file; passed into the
  # tier-builder thread jobs via $vars since runspaces don't inherit
  # parent script scope.
  $http = [Net.Http.HttpClient]::new()
  $http.DefaultRequestHeaders.UserAgent.ParseAdd($crateUserAgent)

  $sha256 = {
    [BitConverter]::ToString(
      [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
    ).Replace('-', '').ToLower()
  }

  # Substitute {arch}, {triple}, {version} in a template string.
  $substTokens = { param($template, $version)
    $template.Replace('{arch}', $script:arch).
    Replace('{triple}', $script:archTriple).
    Replace('{version}', $version)
  }

  $fetchSharedVersions = {
    $nodeTask = $http.GetStringAsync('https://nodejs.org/dist/index.json')
    # ripgrep: crates.io is the canonical registry (BurntSushi publishes
    # there in lock-step with GH releases). Hitting the API there avoids
    # GH's 60 req/hour unauthenticated rate limit.
    $rgTask = $http.GetStringAsync('https://crates.io/api/v1/crates/ripgrep')
    # micro is GH-only, so we resolve the version via the web-side
    # `releases/latest` redirect — github.com (not api.github.com) — which
    # is not subject to the API rate limit. SendAsync with HEAD lets the
    # default HttpClientHandler follow the 301→302 chain; the final
    # RequestUri (.../releases/tag/v<version>) gives us the version.
    $microReq = [Net.Http.HttpRequestMessage]::new(
      [Net.Http.HttpMethod]::Head,
      'https://github.com/micro-editor/micro/releases/latest')
    $microTask = $http.SendAsync($microReq)
    # pnpm: full `latest` metadata in one fetch — gets version, tarball
    # URL, and sha512 SRI in a single ~3 KB response. We use the vanilla
    # `pnpm` package (mjs node-bundle, ~17 MB unpacked) executed against
    # the node we already ship in the base tier, NOT the per-arch
    # @pnpm/linuxstatic-<arch> Node SEA (~140 MB unpacked, ~123 MB of
    # which is bundled node — wasted bytes for us).
    $pnpmTask = $http.GetStringAsync('https://registry.npmjs.org/pnpm/latest')
    $uvTask = $http.GetStringAsync('https://pypi.org/pypi/uv/json')
    [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $pnpmTask, $uvTask)

    $nodeJson = [Text.Json.JsonDocument]::Parse($nodeTask.Result)
    $rgJson = [Text.Json.JsonDocument]::Parse($rgTask.Result)
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
    $script:rgVer = $rgJson.RootElement.GetProperty('crate').GetProperty('max_stable_version').GetString()
    # Final URI after the 301→302 chain looks like
    # `https://github.com/micro-editor/micro/releases/tag/v2.0.15`;
    # take the last path segment and strip the leading 'v'.
    $microFinalUri = $microTask.Result.RequestMessage.RequestUri.ToString()
    $microSeg = $microFinalUri.Substring($microFinalUri.LastIndexOf('/') + 1)
    $script:microVer = $microSeg.TrimStart('v')
    $microTask.Result.Dispose()
    # `pnpm/latest` returns the full version document, so version,
    # tarball URL, and integrity all come from this single response —
    # no second metadata fetch needed.
    $script:pnpmVer = $pnpmJson.RootElement.GetProperty('version').GetString()
    $pnpmDist = $pnpmJson.RootElement.GetProperty('dist')
    $script:pnpmTarballUrl = $pnpmDist.GetProperty('tarball').GetString()
    $script:pnpmNpmIntegrity = $pnpmDist.GetProperty('integrity').GetString()
    $script:uvVer = $uvJson.RootElement.GetProperty('info').GetProperty('version').GetString()

    $nodeJson.Dispose(); $rgJson.Dispose()
    $pnpmJson.Dispose(); $uvJson.Dispose()

    # Mirror lib/tools.sh: fail fast if any upstream returned an unexpected
    # shape so we don't proceed to build malformed download URLs and surface
    # the error far from its cause.
    $missing = [Collections.Generic.List[string]]::new()
    if (-not $script:nodeVer) { $missing.Add('node') }
    if (-not $script:rgVer) { $missing.Add('ripgrep') }
    if (-not $script:microVer) { $missing.Add('micro') }
    if (-not $script:pnpmVer) { $missing.Add('pnpm') }
    if (-not $script:uvVer) { $missing.Add('uv') }
    if ($missing.Count -gt 0) {
      Write-Log E tools fail "failed to fetch one or more tool versions: $($missing -join ', ')"
      throw "failed to fetch tool versions: $($missing -join ', ')"
    }

    if (-not $script:pnpmTarballUrl -or -not $script:pnpmNpmIntegrity) {
      Write-Log E tools fail "pnpm $($script:pnpmVer): missing dist.tarball / dist.integrity"
      throw "pnpm npm metadata missing dist fields"
    }
    # Pinning the URL host to registry.npmjs.org matches the agent-tier
    # policy: a compromised metadata redirect can't point us at an
    # attacker host.
    if (-not $script:pnpmTarballUrl.StartsWith('https://registry.npmjs.org/')) {
      Write-Log E tools fail "pnpm tarball URL not on registry.npmjs.org: $($script:pnpmTarballUrl)"
      throw "pnpm tarball URL not on npm registry"
    }
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

  # POSIX shell-quote a value: wrap in single quotes with each embedded
  # `'` rewritten as `'\''`. Output round-trips through `. file` for any
  # byte sequence — including newlines and quotes — so a manifest value
  # can no longer corrupt the agent-manifest.sh sourced by the wrapper.
  # Must produce byte-identical output to lib/tools.sh's _sh_quote so the
  # generated file is the same regardless of which side built the cache.
  $shQuote = { param([string]$s)
    "'" + $s.Replace("'", "'\''") + "'"
  }

  # Build agent-manifest.sh contents from manifest fields. Mirrors
  # _agent_manifest_sh_contents in lib/tools.sh — exact same output so
  # tier-3 hashes match across sh/ps1 sides.
  $agentManifestShContents = {
    $sb = [Text.StringBuilder]::new(256)
    [void]$sb.Append("AGENT_BINARY=$(& $shQuote $script:agentBinary)`n")
    # Emit launch.flags as a function body so each flag preserves its
    # argument boundary across the manifest → wrapper boundary. A flat
    # space-joined string would lose boundaries on any flag value
    # containing whitespace, an empty string, or shell metacharacters.
    $flags = Get-AgentList '.launch.flags'
    [void]$sb.Append("exec_agent_with_flags() {`n  _eaf_bin=`$1`n  shift`n  exec `"`$_eaf_bin`"")
    foreach ($flag in $flags) {
      [void]$sb.Append(' ')
      [void]$sb.Append((& $shQuote $flag))
    }
    [void]$sb.Append(" `"`$@`"`n}`n")
    # Point the agent's config-dir env var at the system staging path.
    # Skipped for agents whose manifest.configDir.env is empty (Gemini).
    # $crateEnv is shell-name-validated in Invoke-AgentLoad.
    if ($script:crateEnv) {
      [void]$sb.Append("export $($script:crateEnv)=$(& $shQuote $script:crateDir)`n")
    }
    $envKv = Get-AgentKv '.launch.env'
    foreach ($k in $envKv.Keys) {
      if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        Write-Log E launcher fail "invalid launch.env key in $($script:agentManifestPath): '$k' (must match [A-Za-z_][A-Za-z0-9_]*)"
        throw "invalid launch.env key: $k"
      }
      [void]$sb.Append("export $k=$(& $shQuote $envKv[$k])`n")
    }
    $sb.ToString()
  }

  # ── Tier builder ──
  #
  # Shared script block that runs inside each Start-ThreadJob runspace.
  # Thread-job runspaces don't inherit the parent's script scope, so
  # everything is passed as explicit params. For the agent tier, the
  # caller passes prebuilt inputs (tarball URL, bin/entry path, manifest
  # shell-script contents, wrapper source) instead of parsing the manifest
  # inside the job. HttpClient is intentionally NOT passed in — the
  # worker creates and disposes its own so the resource never crosses
  # the call boundary.
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

    # Verify downloaded bytes match an expected sha256 hex digest. Throws
    # before extraction so a hostile tarball can't drop binaries that the
    # build then chmod +x'es. Mirrors lib/tools.sh:_verify_sha256.
    $verifySha256 = { param($bytes, $expected, $label)
      if (-not $expected) {
        Write-Log E "$stage.verify" fail "$label`: empty expected sha256"
        throw "$stage.verify: $label empty expected sha256"
      }
      $actual = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').ToLower()
      $exp = $expected.ToLower()
      if ($actual -ne $exp) {
        Write-Log E "$stage.verify" fail "$label sha256 mismatch (expected $exp, got $actual)"
        throw "$stage.verify: $label sha256 mismatch"
      }
    }

    # Verify downloaded bytes against an npm dist.integrity SRI value
    # (`sha512-<base64>`). Mirrors lib/tools.sh:_verify_npm_integrity.
    $verifyNpmIntegrity = { param($bytes, $integrity, $label)
      if (-not $integrity -or -not $integrity.StartsWith('sha512-')) {
        Write-Log E "$stage.verify" fail "$label`: unsupported integrity algorithm: $integrity"
        throw "$stage.verify: $label unsupported integrity algorithm"
      }
      $expBytes = [Convert]::FromBase64String($integrity.Substring(7))
      $actBytes = [Security.Cryptography.SHA512]::HashData($bytes)
      $eq = ($expBytes.Length -eq $actBytes.Length)
      if ($eq) {
        for ($i = 0; $i -lt $expBytes.Length; $i++) {
          if ($expBytes[$i] -ne $actBytes[$i]) { $eq = $false; break }
        }
      }
      if (-not $eq) {
        $expHex = [BitConverter]::ToString($expBytes).Replace('-', '').ToLower()
        $actHex = [BitConverter]::ToString($actBytes).Replace('-', '').ToLower()
        Write-Log E "$stage.verify" fail "$label sha512 mismatch (expected $expHex, got $actHex)"
        throw "$stage.verify: $label sha512 mismatch"
      }
    }

    # Sidecar checksum files are typically '<hex>  <filename>' (two spaces)
    # or just '<hex>'. Take the first whitespace-delimited token.
    $firstShaToken = { param($shaText)
      if (-not $shaText) { return $null }
      ($shaText.Trim() -split '\s+', 2)[0]
    }

    # Node ships one SHASUMS256.txt covering every platform tarball; pick
    # the row matching our exact filename.
    $nodeShaForName = { param($shaText, $tarballName)
      foreach ($line in ($shaText -split "`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        $parts = $t -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $tarballName) { return $parts[0] }
      }
      return $null
    }

    # Render shims from the node-shim template for every entry in
    # $pkgDir/package.json's `.bin` map. Validates bin names, writes
    # one shim per entry into $outDir, and returns a string array of
    # rendered filenames the caller word-uses as pack inputs.
    #
    # $canonIn / $canonOut route the shim for the bin entry whose
    # name equals $canonIn to filename $canonOut instead of using the
    # bin key. Agent tier passes ($binary, "$binary-bin") so
    # agent-wrapper.sh finds its entry; tool tier passes ('','').
    # Mirrors lib/tools.sh:_render_node_bin_shims — same validation
    # rules, same output shape.
    $renderNodeBinShims = { param($outDir, $pkgDir, $pkgName, $shimTmpl, $canonIn, $canonOut)
      $pkgJsonPath = [IO.Path]::Combine($pkgDir, 'package.json')
      if (-not [IO.File]::Exists($pkgJsonPath)) {
        Write-Log E $stage fail "package.json missing at $pkgJsonPath"
        throw "$stage`: package.json missing"
      }
      $files = [Collections.Generic.List[string]]::new()
      $sawCanon = $false
      $pkgJson = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($pkgJsonPath))
      try {
        # Locate `.bin` via EnumerateObject rather than TryGetProperty:
        # JsonElement.TryGetProperty has three overloads (string,
        # ReadOnlySpan<byte>, ReadOnlySpan<char>) and PowerShell's
        # method binder can't disambiguate when the `out` parameter is
        # passed as `[ref]$x` against an untyped/null variable —
        # surfaces as "Cannot find an overload for TryGetProperty and
        # the argument count: 2" at runtime.
        $binEl = $pkgJson.RootElement
        $hasBin = $false
        foreach ($prop in $pkgJson.RootElement.EnumerateObject()) {
          if ($prop.Name -eq 'bin') { $binEl = $prop.Value; $hasBin = $true; break }
        }
        if (-not $hasBin -or $binEl.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
          Write-Log E $stage fail "$pkgJsonPath`: .bin must be an object"
          throw "$stage`: .bin not an object"
        }
        foreach ($p in $binEl.EnumerateObject()) {
          $binName = $p.Name
          $binPath = $p.Value.GetString()
          # Validate bin key: rejects path separators, shell metas,
          # leading hyphen (would look like a flag), leading dot (no '..').
          if ($binName -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]*$') {
            Write-Log E $stage fail "invalid bin name in $pkgJsonPath`: '$binName'"
            throw "$stage`: invalid bin name '$binName'"
          }
          $entry = $binPath -replace '^\./', ''
          # Validate bin path: must be relative, no traversal, safe
          # segments. Interpolated into the shim's `exec node
          # "$HOME/.local/lib/PKG/{{ENTRY}}"` template — a quote,
          # backslash, control char, or '..' would either break the
          # double-quoted shell literal or escape the package dir.
          # Mirrors the lib/tools.sh validator.
          if (-not $entry -or $entry.StartsWith('/') -or $entry.Contains('\')) {
            Write-Log E $stage fail "invalid bin path in $pkgJsonPath`: '$binPath' (must be a non-empty relative path with no backslashes)"
            throw "$stage`: invalid bin path '$binPath'"
          }
          foreach ($seg in $entry.Split('/')) {
            if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..' -or
                $seg -notmatch '^[A-Za-z0-9._-]+$') {
              Write-Log E $stage fail "invalid bin path segment in $pkgJsonPath`: '$binPath' (segment '$seg' must match [A-Za-z0-9._-]+ and not be '.' or '..')"
              throw "$stage`: invalid bin path segment"
            }
          }
          if ($canonIn -and $binName -eq $canonIn) {
            $target = $canonOut
            $sawCanon = $true
          }
          else {
            $target = $binName
            # Reject aux-shim collisions with reserved agent-tier
            # filenames. Tool tier (no $canonIn) skips this naturally.
            if ($canonIn) {
              if ($target -eq 'agent-manifest.sh' -or
                  $target -eq $canonIn -or
                  $target -eq $canonOut -or
                  $target -eq "$canonIn-pkg") {
                Write-Log E $stage fail "aux bin '$binName' collides with reserved filename '$target'"
                throw "$stage`: aux bin '$binName' collides with reserved filename"
              }
            }
          }
          $shim = $shimTmpl.Replace('{{PKG}}', $pkgName).Replace('{{ENTRY}}', $entry)
          [IO.File]::WriteAllText([IO.Path]::Combine($outDir, $target), $shim)
          [void]$files.Add($target)
        }
      }
      finally { $pkgJson.Dispose() }
      if ($files.Count -eq 0) {
        Write-Log E $stage fail "$pkgJsonPath`: no .bin entries rendered"
        throw "$stage`: no .bin entries rendered"
      }
      if ($canonIn -and -not $sawCanon) {
        Write-Log E $stage fail "canonical bin '$canonIn' not found in $pkgJsonPath"
        throw "$stage`: canonical bin '$canonIn' not found"
      }
      # Return as a fixed array — `,` prefix prevents PowerShell from
      # unwrapping a single-element list into a scalar.
      ,$files.ToArray()
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

    # Per-thread HttpClient — owned and disposed inside this runspace,
    # never received from the parent. UA value travels via $vars
    # because thread runspaces don't inherit parent script scope, so
    # $crateUserAgent (lib/Common.ps1) isn't visible here directly.
    $http = [Net.Http.HttpClient]::new()
    $http.DefaultRequestHeaders.UserAgent.ParseAdd($vars.userAgent)
    $tmpDir = [IO.Path]::Combine([IO.Path]::GetTempPath(), "agent-build-$([Guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tmpDir) > $null
    try {
      $packInputs = $null
      switch ($vars.kind) {
        'base' {
          Write-Log I $stage downloading "node $($vars.nodeVer), ripgrep $($vars.rgVer), micro $($vars.microVer)"
          $nodeTarballName = "node-v$($vars.nodeVer)-linux-$($vars.arch).tar.xz"
          $nodeUrl = "https://nodejs.org/dist/v$($vars.nodeVer)/$nodeTarballName"
          $nodeShaUrl = "https://nodejs.org/dist/v$($vars.nodeVer)/SHASUMS256.txt"
          $rgUrl = "https://github.com/BurntSushi/ripgrep/releases/download/$($vars.rgVer)/ripgrep-$($vars.rgVer)-$($vars.archRg).tar.gz"
          $microUrl = "https://github.com/micro-editor/micro/releases/download/v$($vars.microVer)/micro-$($vars.microVer)-$($vars.archMicro).tar.gz"
          # Fetch artifacts and publisher checksums in parallel. micro
          # uses '.sha' (not '.sha256') as its sidecar suffix.
          $nodeTask = $http.GetByteArrayAsync($nodeUrl)
          $rgTask = $http.GetByteArrayAsync($rgUrl)
          $microTask = $http.GetByteArrayAsync($microUrl)
          $nodeShaTask = $http.GetStringAsync($nodeShaUrl)
          $rgShaTask = $http.GetStringAsync("$rgUrl.sha256")
          $microShaTask = $http.GetStringAsync("$microUrl.sha")
          [Threading.Tasks.Task]::WaitAll($nodeTask, $rgTask, $microTask, $nodeShaTask, $rgShaTask, $microShaTask)

          $nodeExp = & $nodeShaForName $nodeShaTask.Result $nodeTarballName
          $rgExp = & $firstShaToken $rgShaTask.Result
          $microExp = & $firstShaToken $microShaTask.Result
          & $verifySha256 $nodeTask.Result $nodeExp "node $nodeTarballName"
          & $verifySha256 $rgTask.Result $rgExp 'ripgrep'
          & $verifySha256 $microTask.Result $microExp 'micro'

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
          # pnpm vanilla npm package: a Node bundle (mjs entry, ~17 MB
          # unpacked) executed against the base-tier node via the same
          # shim template the agent tier uses for node-bundle agents.
          # Verified against npm's sha512 `dist.integrity` — same
          # trust path as the agent tier.
          $pnpmUrl = $vars.pnpmTarballUrl
          $uvUrl = "https://github.com/astral-sh/uv/releases/download/$($vars.uvVer)/uv-$($vars.archTriple).tar.gz"
          $pnpmTask = $http.GetByteArrayAsync($pnpmUrl)
          $uvTask = $http.GetByteArrayAsync($uvUrl)
          # uv ships a '<url>.sha256' sidecar; pnpm's integrity travels
          # via $vars.pnpmNpmIntegrity (sha512 SRI) instead.
          $uvShaTask = $http.GetStringAsync("$uvUrl.sha256")
          [Threading.Tasks.Task]::WaitAll($pnpmTask, $uvTask, $uvShaTask)

          & $verifyNpmIntegrity $pnpmTask.Result $vars.pnpmNpmIntegrity 'pnpm npm tarball'
          $uvExp = & $firstShaToken $uvShaTask.Result
          & $verifySha256 $uvTask.Result $uvExp 'uv'

          $pnpmTmp = "$tmpDir\_pnpm.tgz"; [IO.File]::WriteAllBytes($pnpmTmp, $pnpmTask.Result)
          $pnpmExtract = "$tmpDir\_pnpm_extract"
          [IO.Directory]::CreateDirectory($pnpmExtract) > $null
          & $mustNative tar -xzf $pnpmTmp -C $pnpmExtract
          [IO.File]::Delete($pnpmTmp)
          $pnpmPkgSrc = "$pnpmExtract\package"
          if (-not [IO.Directory]::Exists($pnpmPkgSrc)) {
            Write-Log E $stage fail "pnpm npm tarball missing 'package/' dir"
            throw "pnpm npm tarball missing 'package/' dir"
          }
          # Relocate package/ → pnpm-pkg/ matching the on-disk layout
          # used for node-bundle agents (~/.local/lib/<name>-pkg/) —
          # setup-tools.sh globs `*-pkg` and moves them into LIB_DIR
          # generically.
          [IO.Directory]::Move($pnpmPkgSrc, "$tmpDir\pnpm-pkg")
          [IO.Directory]::Delete($pnpmExtract, $true)
          # Render one shim per package.json `bin` entry. pnpm publishes
          # 4 (pn, pnx, pnpm, pnpx — pn/pnpm and pnx/pnpx are aliases for
          # the same JS files); shipping them all keeps user-facing
          # invocation parity with `npm i -g pnpm`. No canonical mapping
          # in the tool tier — there's no wrapper layer.
          $pnpmShims = & $renderNodeBinShims $tmpDir "$tmpDir\pnpm-pkg" 'pnpm-pkg' $vars.shimTmpl '' ''

          $uvTmp = "$tmpDir\_uv.tar.gz"; [IO.File]::WriteAllBytes($uvTmp, $uvTask.Result)
          & $mustNative tar -xzf $uvTmp -C $tmpDir --strip-components=1
          [IO.File]::Delete($uvTmp)
          $packInputs = @($pnpmShims) + @('pnpm-pkg', 'uv', 'uvx')
        }
        'agent' {
          Write-Log I $stage downloading "$($vars.agentName) $($vars.agentVer) ($($vars.execType))"
          $tarTmp = "$tmpDir\_agent.tgz"
          $extractDir = "$tmpDir\_extract"
          [IO.Directory]::CreateDirectory($extractDir) > $null
          # Verify against npm dist.integrity (parent resolved this before
          # spawning the job) before we hand the tarball to tar — same
          # threat model as the base/tool tier checksum gate.
          $tarBytes = $http.GetByteArrayAsync($vars.tarballUrl).Result
          & $verifyNpmIntegrity $tarBytes $vars.npmIntegrity "$($vars.agentName) npm tarball"
          [IO.File]::WriteAllBytes($tarTmp, $tarBytes)
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
              # Render one shim per package.json `bin` entry. The
              # canonical entry (key matching .binary) goes to
              # "$binary-bin" so agent-wrapper.sh finds it; auxiliary
              # entries become standalone shims under their bin keys.
              # $agentShims holds the full list of rendered filenames
              # (canonical + aux), spread into $packInputs below.
              $agentShims = & $renderNodeBinShims $tmpDir "$tmpDir\$pkgName" $pkgName $vars.shimTmpl $binary "$binary-bin"
              $packInputs = @($binary, 'agent-manifest.sh') + @($agentShims) + @($pkgName)
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
      # GUID (not $PID) so a stale predictable-named partial from a prior
      # run can't be picked up as ours. The .partial.* glob in the parent
      # cleanup still matches because we keep the suffix shape.
      $tmp = "$archive.partial.$([Guid]::NewGuid().ToString('N'))"
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
    finally {
      $http.Dispose()
      try { [IO.Directory]::Delete($tmpDir, $true) } catch {}
    }
  }

  # ── Orchestration ──

  try {

    [IO.Directory]::CreateDirectory($toolsDir) > $null
    # Reap ORPHAN partials from prior builds that crashed. The cache dir
    # is shared across concurrent launchers — a blanket delete would
    # race-delete another active launcher's in-progress archive (its
    # File.Move would then fail). Each launch's partial is uniquely
    # named via Guid.NewGuid(); a successful build always consumes its
    # own partial via File.Move. Anything older than the threshold is
    # by definition abandoned, so age-gating cleanup never touches a
    # live builder's file.
    # GetFiles (not EnumerateFiles) so the file list is materialized up
    # front — deleting during enumeration can invalidate the enumerator
    # and skip entries on some filesystems.
    $stalePartialCutoff = (Get-Date).AddHours(-1)
    foreach ($stale in [IO.Directory]::GetFiles($toolsDir, '*.partial.*')) {
      try {
        if ([IO.FileInfo]::new($stale).LastWriteTime -lt $stalePartialCutoff) {
          [IO.File]::Delete($stale)
        }
      }
      catch {}
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
      # arch:$arch in the seed because the packed binaries (node, rg,
      # micro) are architecture-specific. Without it, an x64 and an
      # arm64 host sharing $toolsDir (a roaming-profile cache, an Apple
      # Silicon dev switching between Rosetta and native, CI matrix
      # with a shared build cache) collide on the same `base-*.tar.xz`
      # filename and inject the wrong binaries. Matches the agent-tier
      # seed below which already includes $arch.
      $baseHash = & $sha256 "base-arch:$($script:arch)-node:$nodeVer-rg:$rgVer-micro:$microVer"
      $script:baseArchive = "$toolsDir\base-$baseHash.tar.xz"
    }
    # Shim template bytes — both tool tier (pnpm) and agent tier
    # (node-bundle agents) render this template, so changes to it must
    # bust both tier caches AND must be passed into both thread-jobs
    # for rendering. Loaded once on the parent side; $lfOnly collapses
    # CRLF→LF so sh-side hashing matches regardless of the source
    # file's on-disk line endings.
    $shimTmpl = & $lfOnly ([IO.File]::ReadAllText("$projectRoot\bin\node-shim.sh.tmpl"))

    if ($optToolHash) {
      $script:toolArchive = & $resolveArchive 'tool' $optToolHash
    }
    else {
      # arch:$arch covers uv (per-arch native binary). pnpm is now JS,
      # so its bytes are arch-agnostic — but the archive is shared
      # with uv, so $arch stays in the seed. Include shim template
      # since pnpm's `pnpm` entry is the rendered shim.
      $toolHash = & $sha256 "tool-arch:$($script:arch)-pnpm:$pnpmVer-uv:$uvVer-shim:$shimTmpl"
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
      # source in the hash.
      $manifestSrc = & $lfOnly ([IO.File]::ReadAllText($agentManifestPath))
      $wrapperSrc = & $lfOnly ([IO.File]::ReadAllText("$projectRoot\bin\agent-wrapper.sh"))
      $agentHash = & $sha256 "agent:$agent-ver:$agentVer-arch:$arch-manifest:$manifestSrc-manifest-sh:$manifestShContents-wrapper:$wrapperSrc-shim:$shimTmpl"
      $script:agentArchive = "$toolsDir\$agent-$agentHash.tar.xz"
    }

    $baseVars = @{
      kind = 'base'
      userAgent = $crateUserAgent
      nodeVer = $script:nodeVer; rgVer = $script:rgVer; microVer = $script:microVer
      arch = $script:arch; archRg = $script:archRg; archMicro = $script:archMicro
    }
    $toolVars = @{
      kind = 'tool'
      userAgent = $crateUserAgent
      pnpmVer = $script:pnpmVer; uvVer = $script:uvVer
      arch = $script:arch; archTriple = $script:archTriple
      pnpmTarballUrl = $script:pnpmTarballUrl
      pnpmNpmIntegrity = $script:pnpmNpmIntegrity
      shimTmpl = $shimTmpl
    }
    # Agent-tier inputs are only needed when the tier will actually
    # build. When pinned (-AgentHash …), $tierBuilder verifies the
    # cached archive and returns before reading $vars, so we skip the
    # parsing, {version} substitution, and npm dist.integrity fetch
    # entirely — otherwise pinned/offline launches throw on the
    # network call below. Mirrors lib/tools.sh:_build_agent_tier,
    # which gates the same prep behind OPT_AGENT_HASH.
    if (-not $optAgentHash) {
      $execType = Get-AgentField '.executable.type'
      $tarballUrl = & $substTokens (Get-AgentField '.executable.tarballUrl') $script:agentVer
      $binPath = Get-AgentField '.executable.binPath'
      if ($binPath) { $binPath = & $substTokens $binPath $script:agentVer }
      $wrapperSrcForPack = & $lfOnly ([IO.File]::ReadAllText("$projectRoot\bin\agent-wrapper.sh"))

      # Resolve npm package name AND tarball-version from the URL. The
      # version we look up MUST match the tarball we download — codex
      # publishes per-platform binaries as version-suffixed releases
      # ('0.125.0-linux-x64', '0.125.0-darwin-arm64', …) under the same
      # '@openai/codex' package, so the integrity for '0.125.0' (the JS
      # wrapper) is NOT the integrity for '0.125.0-linux-x64' (the
      # platform binary we actually fetch). Extract the version from the
      # tarball's basename instead of using $script:agentVer, which only
      # knows the wrapper's version. URL shape:
      # '<scope>/<name>/-/<basename>-<version>.tgz'. Restrict to
      # registry.npmjs.org so a manifest can't redirect verification at
      # an attacker-controlled metadata host.
      if (-not $tarballUrl.StartsWith('https://registry.npmjs.org/')) {
        Write-Log E "tools.$agent" fail "unsupported tarball host (only registry.npmjs.org is allowed): $tarballUrl"
        throw "unsupported tarball host: $tarballUrl"
      }
      $npmRest = $tarballUrl.Substring('https://registry.npmjs.org/'.Length)
      $npmSepIdx = $npmRest.IndexOf('/-/')
      if ($npmSepIdx -lt 0) {
        Write-Log E "tools.$agent" fail "tarball URL missing '/-/' separator: $tarballUrl"
        throw "tarball URL missing /-/ separator"
      }
      $npmPkg = $npmRest.Substring(0, $npmSepIdx)
      $npmFilename = $npmRest.Substring($npmSepIdx + '/-/'.Length)
      $npmPkgBase = $npmPkg.Substring($npmPkg.LastIndexOf('/') + 1)
      $npmExpectedPrefix = "$npmPkgBase-"
      if (-not $npmFilename.StartsWith($npmExpectedPrefix) -or -not $npmFilename.EndsWith('.tgz')) {
        Write-Log E "tools.$agent" fail "tarball filename does not match '<pkg>-<version>.tgz' shape: $npmFilename (pkg=$npmPkgBase)"
        throw "tarball filename shape mismatch: $npmFilename"
      }
      $npmTarVer = $npmFilename.Substring($npmExpectedPrefix.Length, $npmFilename.Length - $npmExpectedPrefix.Length - '.tgz'.Length)
      $npmMetaUrl = "https://registry.npmjs.org/$npmPkg/$npmTarVer"
      $npmMetaJson = $http.GetStringAsync($npmMetaUrl).Result
      $npmMetaDoc = [Text.Json.JsonDocument]::Parse($npmMetaJson)
      try {
        $npmIntegrity = $npmMetaDoc.RootElement.GetProperty('dist').GetProperty('integrity').GetString()
      }
      finally { $npmMetaDoc.Dispose() }
      if (-not $npmIntegrity) {
        Write-Log E "tools.$agent" fail "no dist.integrity at $npmMetaUrl"
        throw "no dist.integrity for $agent"
      }

      $agentVars = @{
        kind = 'agent'
        userAgent = $crateUserAgent
        agentName = $agent; agentBinary = $script:agentBinary
        agentVer = $script:agentVer
        execType = $execType
        tarballUrl = $tarballUrl
        binPath = $binPath
        manifestShContents = $manifestShContents
        wrapperSrc = $wrapperSrcForPack
        shimTmpl = $shimTmpl
        npmIntegrity = $npmIntegrity
      }
    }
    else {
      $agentVars = @{}
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
  finally { $http.Dispose() }
}
