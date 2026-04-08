#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRED_PATH="$SCRIPT_DIR/.credentials.json"

if [ ! -f "$CRED_PATH" ]; then
  echo "Credentials file not found. Run 'claude' to authenticate." >&2
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED_PATH")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "No OAuth credentials. Run 'claude' to authenticate." >&2
  exit 1
fi

TEST_STATUS=$(curl -sSL -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  'https://api.anthropic.com/api/oauth/claude_cli/roles') || TEST_STATUS="000"

if [ "$TEST_STATUS" = "401" ]; then
  REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken // empty' "$CRED_PATH")
  if [ -z "$REFRESH_TOKEN" ]; then
    echo "Token expired, no refresh token. Run 'claude' to re-authenticate." >&2
    exit 1
  fi
  OAUTH=$(jq -r '"\(.client_id)\n\(.scope)"' "$SCRIPT_DIR/oauth.json")
  OAUTH_CLIENT_ID=$(printf '%s' "$OAUTH" | head -1)
  OAUTH_SCOPE=$(printf '%s' "$OAUTH" | tail -1)
  BODY=$(jq -nc \
    --arg rt "$REFRESH_TOKEN" \
    --arg cid "$OAUTH_CLIENT_ID" \
    --arg scope "$OAUTH_SCOPE" \
    '{grant_type:"refresh_token",refresh_token:$rt,client_id:$cid,scope:$scope}')
  RESPONSE=$(curl -sSL -X POST 'https://platform.claude.com/v1/oauth/token' \
    -H 'Content-Type: application/json' \
    -d "$BODY" 2>/dev/null) || RESPONSE=""
  PARSED=$(printf '%s' "$RESPONSE" | jq -r '"\(.access_token // "")\n\(.expires_in // "")\n\(.refresh_token // "")"' 2>/dev/null)
  NEW_ACCESS=$(printf '%s' "$PARSED" | sed -n '1p')
  if [ -z "$NEW_ACCESS" ]; then
    echo "OAuth refresh failed. Run 'claude' to re-authenticate." >&2
    exit 1
  fi
  EXPIRES_IN=$(printf '%s' "$PARSED" | sed -n '2p')
  if [ -z "$EXPIRES_IN" ]; then
    echo "OAuth refresh response missing expires_in." >&2
    exit 1
  fi
  NOW_MS=$(($(date +%s) * 1000))
  EXPIRES_AT=$((NOW_MS + EXPIRES_IN * 1000))
  NEW_REFRESH=$(printf '%s' "$PARSED" | sed -n '3p')
  CRED_NEW=$(jq -c \
    --arg at "$NEW_ACCESS" \
    --argjson ea "$EXPIRES_AT" \
    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.expiresAt = $ea' \
    "$CRED_PATH")
  if [ -n "$NEW_REFRESH" ]; then
    CRED_NEW=$(printf '%s' "$CRED_NEW" | jq -c --arg rt "$NEW_REFRESH" '.claudeAiOauth.refreshToken = $rt')
  fi
  printf '%s\n' "$CRED_NEW" > "$CRED_PATH"
elif [ "$TEST_STATUS" != "200" ]; then
  echo "Credential check failed (HTTP $TEST_STATUS)." >&2
  exit 1
fi
