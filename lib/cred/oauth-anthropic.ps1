# oauth-anthropic.ps1 — Anthropic (Claude Code) OAuth refresh strategy.
# Dot-sourced by Ensure-Credential.ps1. Defines Invoke-CredCheck.

function Invoke-CredCheck {
  param(
    [Parameter(Mandatory)][string]$CredPath,
    [Parameter(Mandatory)][string]$OauthJsonPath,
    [Net.Http.HttpClient]$Http
  )
  $credText = [IO.File]::ReadAllText($CredPath)
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

  if ($testRes.StatusCode -eq [Net.HttpStatusCode]::OK) {
    Write-Log I cred ok 'access token valid'
    return
  }
  if ($testRes.StatusCode -ne [Net.HttpStatusCode]::Unauthorized) {
    Write-Log E cred fail "credential check failed (HTTP $($testRes.StatusCode))"
    throw "credential check failed (HTTP $($testRes.StatusCode))"
  }

  Write-Log I cred refresh 'access token expired (HTTP 401)'
  if (-not $refreshToken) {
    Write-Log E cred fail 'token expired and no refresh token; run "claude" to re-authenticate'
    throw 'no refresh token'
  }

  $oauthDoc = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($OauthJsonPath))
  $endpoint = $oauthDoc.RootElement.GetProperty('token_endpoint').GetString()
  $clientId = $oauthDoc.RootElement.GetProperty('client_id').GetString()
  $scope = $oauthDoc.RootElement.GetProperty('scope').GetString()
  $oauthDoc.Dispose()

  $bodyJson = [Text.Json.Nodes.JsonObject]::new()
  $bodyJson.Add('grant_type', [Text.Json.Nodes.JsonValue]::Create('refresh_token'))
  $bodyJson.Add('refresh_token', [Text.Json.Nodes.JsonValue]::Create($refreshToken))
  $bodyJson.Add('client_id', [Text.Json.Nodes.JsonValue]::Create($clientId))
  $bodyJson.Add('scope', [Text.Json.Nodes.JsonValue]::Create($scope))

  $refreshRes = $Http.PostAsync(
    $endpoint,
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
  [IO.File]::WriteAllText($CredPath, $credNew.ToJsonString())
  Write-Log I cred ok "refreshed (expires in ${expiresIn}s)"
}
