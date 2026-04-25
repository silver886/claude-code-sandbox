# Build-Image.ps1 — build Podman base image if needed.
# Dot-sourced (not executed). Requires: $projectRoot, $sha256 (from Tools.ps1)
# Reads: $Image (base OS image name), $forcePull
#
# Sets: $imageTag

$imageSrc = {
  $files = @(
    "$projectRoot\Containerfile",
    "$projectRoot\lib\log.sh",
    "$projectRoot\bin\enable-dnf.sh",
    "$projectRoot\bin\setup-tools.sh",
    "$projectRoot\config\sudoers-enable-dnf.tmpl"
  )
  $sb = [Text.StringBuilder]::new(256)
  foreach ($f in $files) {
    [void]$sb.Append((& $sha256 ([IO.File]::ReadAllText($f).Replace("`r`n", "`n"))))
  }
  $sb.ToString()
}

$buildBaseImage = {
  $script:imageTag = "sandbox-base-$(& $sha256 "$(& $imageSrc)-$Image")"
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
