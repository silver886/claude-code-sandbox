param(
  [Net.Http.HttpClient]$Http = [Net.Http.HttpClient]::new(),
  # The launcher passes -LogLevel explicitly. Standalone callers can
  # omit it and get the default (W).
  [ValidateSet('I', 'W', 'E')][string]$LogLevel = 'W'
)
$ErrorActionPreference = 'Stop'

# Script-scoped LogLevel for Write-Log to read. No env var write,
# no caller pollution — dies with this script.
$script:LogLevel = $LogLevel

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir
. "$projectRoot\lib\Log.ps1"

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($HOME, '.claude') }
$credPath = [IO.Path]::Combine($configDir, '.credentials.json')

Write-Log I cred check $credPath

if (-not [IO.File]::Exists($credPath)) {
  Write-Log E cred fail 'credentials file not found; run "claude" to authenticate'
  throw 'credentials file not found'
}

$credText = [IO.File]::ReadAllText($credPath)
$credJson = [Text.Json.JsonDocument]::Parse($credText)
$accessToken = $null
$refreshToken = $null
try {
  $oauth = $credJson.RootElement.GetProperty('claudeAiOauth')
  $accessToken = $oauth.GetProperty('accessToken').GetString()
  $refreshToken = try { $oauth.GetProperty('refreshToken').GetString() } catch { $null }
}
catch {}

$credJson.Dispose()
if (-not $accessToken) {
  Write-Log E cred fail 'no OAuth credentials; run "claude" to authenticate'
  throw 'no OAuth credentials'
}

$testReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.anthropic.com/api/oauth/claude_cli/roles')
$testReq.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)
$testRes = $Http.SendAsync($testReq).Result
if ($testRes.StatusCode -eq [Net.HttpStatusCode]::Unauthorized) {
  Write-Log I cred refresh 'access token expired (HTTP 401)'
  if (-not $refreshToken) {
    Write-Log E cred fail 'token expired and no refresh token; run "claude" to re-authenticate'
    throw 'no refresh token'
  }

  $oauthJson = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText([IO.Path]::Combine($projectRoot, 'config', 'oauth.json')))
  $bodyJson = [Text.Json.Nodes.JsonObject]::new()
  $bodyJson.Add('grant_type', [Text.Json.Nodes.JsonValue]::Create('refresh_token'))
  $bodyJson.Add('refresh_token', [Text.Json.Nodes.JsonValue]::Create($refreshToken))
  $bodyJson.Add('client_id', [Text.Json.Nodes.JsonValue]::Create($oauthJson.RootElement.GetProperty('client_id').GetString()))
  $bodyJson.Add('scope', [Text.Json.Nodes.JsonValue]::Create($oauthJson.RootElement.GetProperty('scope').GetString()))
  $oauthJson.Dispose()

  $refreshRes = $Http.PostAsync(
    'https://platform.claude.com/v1/oauth/token',
    [Net.Http.StringContent]::new($bodyJson.ToJsonString(), [Text.Encoding]::UTF8, 'application/json')
  ).Result
  if (-not $refreshRes.IsSuccessStatusCode) {
    Write-Log E cred fail "OAuth refresh failed (HTTP $($refreshRes.StatusCode)); run 'claude' to re-authenticate"
    throw "OAuth refresh failed (HTTP $($refreshRes.StatusCode))"
  }

  $refreshJson = [Text.Json.JsonDocument]::Parse($refreshRes.Content.ReadAsStringAsync().Result)
  $r = $refreshJson.RootElement
  $expiresIn = $r.GetProperty('expires_in').GetInt64()

  $credNew = [Text.Json.Nodes.JsonNode]::Parse($credText)
  $credNew['claudeAiOauth']['accessToken'] = [Text.Json.Nodes.JsonValue]::Create($r.GetProperty('access_token').GetString())
  $credNew['claudeAiOauth']['expiresAt'] = [Text.Json.Nodes.JsonValue]::Create(
    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $expiresIn * 1000
  )

  $newRefresh = try { $r.GetProperty('refresh_token').GetString() } catch { $null }
  if ($newRefresh) {
    $credNew['claudeAiOauth']['refreshToken'] = [Text.Json.Nodes.JsonValue]::Create($newRefresh)
  }

  $refreshJson.Dispose()
  [IO.File]::WriteAllText($credPath, $credNew.ToJsonString())
  Write-Log I cred ok "refreshed (expires in ${expiresIn}s)"
}
elseif ($testRes.StatusCode -eq [Net.HttpStatusCode]::OK) {
  Write-Log I cred ok 'access token valid'
}
else {
  Write-Log E cred fail "credential check failed (HTTP $($testRes.StatusCode))"
  throw "credential check failed (HTTP $($testRes.StatusCode))"
}
