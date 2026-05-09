# Build-Image.ps1 — build Podman base image if needed.
# Dot-sourced (not executed). Requires: $projectRoot
# Reads: $Image (base OS image name), $forcePull
#
# Sets: $imageTag (via $script:)
#
# Top-level surface is $buildBaseImage only — sha256 helper and the
# image-source enumeration are scoped inside it so dot-sourcing this
# file doesn't pollute the launcher scope.

$buildBaseImage = {
  $sha256 = {
    [BitConverter]::ToString(
      [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($args[0]))
    ).Replace('-', '').ToLower()
  }

  $imageSrc = {
    $files = @(
      "$projectRoot\Containerfile",
      "$projectRoot\.containerignore",
      "$projectRoot\lib\log.sh",
      "$projectRoot\bin\enable-dnf.sh",
      "$projectRoot\bin\setup-tools.sh",
      "$projectRoot\config\sudoers-enable-dnf.tmpl"
    )
    $sb = [Text.StringBuilder]::new(256)
    foreach ($f in $files) {
      [void]$sb.Append((& $sha256 (& $lfOnly ([IO.File]::ReadAllText($f)))))
    }
    $sb.ToString()
  }

  $script:imageTag = "crate-base-$(& $sha256 "$(& $imageSrc)-$Image")"
  podman image exists $script:imageTag 2>$null
  if ($LASTEXITCODE -eq 0 -and -not $forcePull) {
    Write-Log I image cache-hit $script:imageTag
    return
  }
  Write-Log I image build $script:imageTag
  # Canonicalize $projectRoot through reparse points in every path
  # component — podman tars the build context by physical path on
  # Windows, so a junction'd ancestor can fault mid-archive. Walk
  # top-down from the drive root, re-resolving wherever LinkType is
  # set. Mirrors `pwd -P` on the POSIX launchers.
  $stack = [Collections.Generic.Stack[string]]::new()
  $cur = Get-Item -LiteralPath $projectRoot -Force
  while ($cur.Parent) { $stack.Push($cur.Name); $cur = $cur.Parent }
  $buildCtx = $cur.FullName
  while ($stack.Count -gt 0) {
    $buildCtx = [IO.Path]::Combine($buildCtx, $stack.Pop())
    $info = Get-Item -LiteralPath $buildCtx -Force
    if ($info.LinkType) { $buildCtx = $info.ResolveLinkTarget($true).FullName }
  }
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $script:imageTag)
  if ($forcePull) { $buildArgs += '--no-cache' }
  if ($selinuxOpt) { $buildArgs += $selinuxOpt }
  $buildArgs += '-f'
  $buildArgs += (Join-Path $buildCtx 'Containerfile')
  $buildArgs += $buildCtx
  Invoke-Must podman @buildArgs
  Write-Log I image built $script:imageTag
}
