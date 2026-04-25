#!/bin/sh
# oauth-openai.sh — OpenAI Codex PKCE public-client refresh strategy.
# Sourced by ensure-credential.sh. Requires: CRED_PATH, AGENT_OAUTH_JSON, log().
#
# Live-probe: hit auth.openai.com/oauth/userinfo with the access token
# in a Bearer header. HTTP 200 = valid, HTTP 401 = expired (refresh).
# Same pattern as Anthropic/Google — tolerant of host-clock skew.
#
# Auth file schema (per codex-rs/login/src/auth/storage.rs +
# token_data.rs custom serde):
#   { auth_mode, tokens: { id_token (JWT string), access_token,
#     refresh_token, account_id? }, last_refresh }
# id_token is stored on disk as the raw JWT string. Codex parses the
# struct fields out of the JWT on load — we don't decode it here.
# PKCE public-client: no client_secret on refresh, and scope is not sent.

cred_check() {
  ACCESS_TOKEN=$(jq -r '.tokens.access_token // empty' "$CRED_PATH")
  if [ -z "$ACCESS_TOKEN" ]; then
    log E cred fail "no OAuth credentials in $CRED_PATH; run 'codex login' to authenticate"
    exit 1
  fi

  _status=$(curl -sSL -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    'https://auth.openai.com/oauth/userinfo') || _status="000"

  if [ "$_status" = "200" ]; then
    log I cred ok "access token valid"
    return 0
  fi
  if [ "$_status" != "401" ]; then
    log E cred fail "credential check failed (HTTP $_status)"
    exit 1
  fi

  log I cred refresh "access token expired (HTTP 401)"
  _refresh=$(jq -r '.tokens.refresh_token // empty' "$CRED_PATH")
  if [ -z "$_refresh" ]; then
    log E cred fail "token expired and no refresh token; run 'codex login' to re-authenticate"
    exit 1
  fi

  _cid=$(jq -r '.client_id'           "$AGENT_OAUTH_JSON")
  _endpoint=$(jq -r '.token_endpoint' "$AGENT_OAUTH_JSON")

  _body=$(jq -nc \
    --arg rt "$_refresh" \
    --arg cid "$_cid" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid}')

  _response=$(curl -sSL -X POST "$_endpoint" \
    -H 'Content-Type: application/json' \
    -d "$_body" 2>/dev/null) || _response=""

  _new_access=$(printf '%s' "$_response" | jq -r '.access_token // empty')
  _new_id=$(printf '%s'     "$_response" | jq -r '.id_token     // empty')
  if [ -z "$_new_access" ] || [ -z "$_new_id" ]; then
    log E cred fail "OAuth refresh failed; run 'codex login' to re-authenticate"
    exit 1
  fi
  _new_refresh=$(printf '%s' "$_response" | jq -r '.refresh_token // empty')

  _now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  _cred_new=$(jq -c \
    --arg at  "$_new_access" \
    --arg it  "$_new_id" \
    --arg now "$_now_iso" \
    '.tokens.access_token = $at
     | .tokens.id_token = $it
     | .last_refresh = $now' \
    "$CRED_PATH")
  if [ -n "$_new_refresh" ]; then
    _cred_new=$(printf '%s' "$_cred_new" | jq -c --arg rt "$_new_refresh" '.tokens.refresh_token = $rt')
  fi
  printf '%s' "$_cred_new" > "$CRED_PATH"
  log I cred ok "refreshed"
}
