param(
  [Parameter(Mandatory)][string]$Agent,
  [Net.Http.HttpClient]$Http = [Net.Http.HttpClient]::new(),
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'

$LogLevel = $LogLevel.ToUpperInvariant()
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = [IO.Path]::GetDirectoryName($scriptDir)
. "$projectRoot\lib\Log.ps1"
. "$projectRoot\lib\Agent.ps1"

$agent = $Agent
Invoke-AgentLoad

$strategy = Get-AgentField '.credential.strategy'
$strategySrc = [IO.Path]::Combine($projectRoot, 'lib', 'cred', "$strategy.ps1")
if (-not [IO.File]::Exists($strategySrc)) {
  Write-Log E cred fail "unknown credential strategy: $strategy"
  throw "unknown credential strategy: $strategy"
}

$rwFirst = (Get-AgentList '.files.rw')[0]
if (-not $rwFirst) {
  Write-Log E cred fail "manifest has no files.rw entries"
  throw "no rw entries"
}
$credPath = [IO.Path]::Combine($agentConfigDir, $rwFirst)
$agentOauthJson = [IO.Path]::Combine($agentDir, 'oauth.json')

Write-Log I cred check "$credPath ($strategy)"
if (-not [IO.File]::Exists($credPath)) {
  Write-Log E cred fail "credentials file not found: $credPath; run '$agent' to authenticate"
  throw "credentials file not found"
}

. $strategySrc
Invoke-CredCheck -CredPath $credPath -OauthJsonPath $agentOauthJson -Http $Http
