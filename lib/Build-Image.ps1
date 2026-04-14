# Build-Image.ps1 — build Podman base image if needed.
# Dot-sourced (not executed). Requires: $projectRoot, $sha256 (from Tools.ps1)
# Reads: $Image (base OS image name), $forcePull
#
# $buildBaseImage: ensures the base container image exists.
# Sets: $imageTag

$imageSrc = {
  # Hash each input file independently and concatenate the digests so
  # file-boundary content can't collide when the contents are shifted.
  # Line endings normalized so the Windows-side hash matches the
  # Linux-side podman-container.sh hash for the same checkout.
  $files = @(
    "$projectRoot\Containerfile",
    "$projectRoot\bin\enable-dnf.sh",
    "$projectRoot\bin\setup-tools.sh",
    "$projectRoot\config\sudoers-claude-enable-dnf"
  )
  -join ($files | ForEach-Object {
    & $sha256 ([IO.File]::ReadAllText($_).Replace("`r`n", "`n"))
  })
}

$buildBaseImage = {
  $script:imageTag = "claude-base-$(& $sha256 "$(& $imageSrc)-$Image")"
  podman image exists $script:imageTag 2>$null
  if ($LASTEXITCODE -eq 0 -and -not $forcePull) {
    Write-Log I image cache-hit $script:imageTag
    return
  }
  Write-Log I image build $script:imageTag
  $buildArgs = @('image', 'build', '--build-arg', "BASE_IMAGE=$Image", '--tag', $script:imageTag)
  if ($forcePull) { $buildArgs += '--no-cache' }
  $buildArgs += $projectRoot
  Invoke-Must podman @buildArgs
  Write-Log I image built $script:imageTag
}
