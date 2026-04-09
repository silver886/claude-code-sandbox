param(
  [Net.Http.HttpClient]$Http = [Net.Http.HttpClient]::new()
)
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [IO.Path]::Combine($HOME, '.claude') }
$credPath = [IO.Path]::Combine($configDir, '.credentials.json')
if (-not [IO.File]::Exists($credPath)) {
  throw 'Credentials file not found. Run "claude" to authenticate.'
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
  throw 'No OAuth credentials. Run "claude" to authenticate.'
}

$testReq = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, 'https://api.anthropic.com/api/oauth/claude_cli/roles')
$testReq.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $accessToken)
$testRes = $Http.SendAsync($testReq).Result
if ($testRes.StatusCode -eq [Net.HttpStatusCode]::Unauthorized) {
  if (-not $refreshToken) {
    throw 'Token expired, no refresh token. Run "claude" to re-authenticate.'
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
    throw "OAuth refresh failed (HTTP $($refreshRes.StatusCode)). Run ""claude"" to re-authenticate."
  }

  $refreshJson = [Text.Json.JsonDocument]::Parse($refreshRes.Content.ReadAsStringAsync().Result)
  $r = $refreshJson.RootElement

  $credNew = [Text.Json.Nodes.JsonNode]::Parse($credText)
  $credNew['claudeAiOauth']['accessToken'] = [Text.Json.Nodes.JsonValue]::Create($r.GetProperty('access_token').GetString())
  $credNew['claudeAiOauth']['expiresAt'] = [Text.Json.Nodes.JsonValue]::Create(
    [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $r.GetProperty('expires_in').GetInt64() * 1000
  )

  $newRefresh = try { $r.GetProperty('refresh_token').GetString() } catch { $null }
  if ($newRefresh) {
    $credNew['claudeAiOauth']['refreshToken'] = [Text.Json.Nodes.JsonValue]::Create($newRefresh)
  }

  $refreshJson.Dispose()
  [IO.File]::WriteAllText($credPath, $credNew.ToJsonString())
}
elseif ($testRes.StatusCode -ne [Net.HttpStatusCode]::OK) {
  throw "Credential check failed (HTTP $($testRes.StatusCode))."
}
