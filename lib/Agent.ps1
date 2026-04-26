# Agent.ps1 — manifest loader for multi-agent sandbox. Dot-sourced
# (not executed). Requires: $projectRoot, $agent (set by launcher).
#
# Sets (script scope) after Invoke-AgentLoad:
#   $agentDir           — $projectRoot\agent\<agent>
#   $agentManifestPath  — path to manifest.json
#   $agentManifest      — parsed PSCustomObject
#   $agentBinary        — e.g. "claude"
#   $agentProjectDir    — e.g. ".claude"
#   $agentConfigDir     — expanded host config dir (respects env override)
#   $crateDir           — in-sandbox config dir (mount target)
#   $crateEnv           — env var name the wrapper sets inside the sandbox
#                         to point at $crateDir; empty if the agent
#                         has no config-dir env var (Gemini)
#
# Sandbox-side path policy (see lib/agent.sh for the rationale):
#   - With configDir.env present, stage at /usr/local/etc/crate/<agent>
#     and let the wrapper export the env var.
#   - Without it, mount at the default path with $HOME rewritten to /home/agent.
#
# Helpers:
#   Get-AgentField $path  — dotted path lookup, returns $null if missing
#   Get-AgentList  $path  — array of strings (empty array if missing)
#   Get-AgentKv    $path  — hashtable of string → string

function Invoke-AgentLoad {
  $script:agentDir = [IO.Path]::Combine($projectRoot, 'agent', $agent)
  $script:agentManifestPath = [IO.Path]::Combine($agentDir, 'manifest.json')
  if (-not [IO.File]::Exists($script:agentManifestPath)) {
    Write-Log E launcher fail "unknown agent: $agent (no $($script:agentManifestPath))"
    throw "unknown agent: $agent"
  }

  $script:agentManifest = [IO.File]::ReadAllText($script:agentManifestPath) |
    ConvertFrom-Json
  $script:agentBinary     = $script:agentManifest.binary
  $script:agentProjectDir = $script:agentManifest.projectDir

  $envName = $script:agentManifest.configDir.env
  $defaultPath = $script:agentManifest.configDir.default
  $script:agentConfigDir = ''
  if ($envName) {
    $override = [Environment]::GetEnvironmentVariable($envName)
    if ($override) { $script:agentConfigDir = $override }
  }
  if (-not $script:agentConfigDir) {
    if ($defaultPath.StartsWith('$HOME')) {
      $script:agentConfigDir = $HOME + $defaultPath.Substring('$HOME'.Length)
    }
    else {
      $script:agentConfigDir = $defaultPath
    }
  }

  $script:crateEnv = $envName
  if ($envName) {
    $script:crateDir = "/usr/local/etc/crate/$agent"
  }
  elseif ($defaultPath.StartsWith('$HOME')) {
    $script:crateDir = '/home/agent' + $defaultPath.Substring('$HOME'.Length)
  }
  else {
    $script:crateDir = $defaultPath
  }
}

function Get-AgentField {
  param([string]$Path)
  $cur = $script:agentManifest
  foreach ($seg in $Path.TrimStart('.').Split('.')) {
    if ($null -eq $cur) { return $null }
    if ($cur.PSObject.Properties.Name -notcontains $seg) { return $null }
    $cur = $cur.$seg
  }
  $cur
}

function Get-AgentList {
  param([string]$Path)
  $v = Get-AgentField $Path
  if ($null -eq $v) { return @() }
  [string[]]$v
}

function Get-AgentKv {
  param([string]$Path)
  $v = Get-AgentField $Path
  $h = [ordered]@{}
  if ($null -eq $v) { return $h }
  foreach ($p in $v.PSObject.Properties) {
    $h[$p.Name] = [string]$p.Value
  }
  $h
}
