#!/bin/bash

# Check if credentials file exists
# First check XDG_CONFIG_HOME, then fall back to ~/.claude
if [ -n "$XDG_CONFIG_HOME" ] && [ -f "$XDG_CONFIG_HOME/claude/.credentials.json" ]; then
    CREDENTIALS_FILE="$XDG_CONFIG_HOME/claude/.credentials.json"
elif [ -f "$HOME/.claude/.credentials.json" ]; then
    CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
else
    echo "Error: Credentials file not found at $XDG_CONFIG_HOME/claude/.credentials.json or $HOME/.claude/.credentials.json"
    exit 1
fi

# Check if gitea url and token arguments are provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 <gitea-url> [gitea-token]"
    echo "Example: $0 https://git.dominik-roth.eu \$GITEA_TOKEN"
    echo "You can also set GITEA_TOKEN environment variable instead of passing it as argument"
    exit 1
fi

GITEA_URL="$1"
GITEA_TOKEN="${2:-$GITEA_TOKEN}"

if [ -z "$GITEA_TOKEN" ]; then
    echo "Error: Gitea token not provided. Set GITEA_TOKEN environment variable or pass as third argument"
    exit 1
fi

# Read the entire claudeAiOauth object from JSON file
CLAUDE_CREDENTIALS=$(jq -c '.claudeAiOauth' "$CREDENTIALS_FILE")

# Check if jq successfully extracted the object
if [ "$CLAUDE_CREDENTIALS" = "null" ] || [ -z "$CLAUDE_CREDENTIALS" ]; then
    echo "Error: Could not read claudeAiOauth from credentials file"
    exit 1
fi

# Wrap it in the expected format
FULL_CREDENTIALS="{\"claudeAiOauth\":$CLAUDE_CREDENTIALS}"

echo "Setting CLAUDE_CREDENTIALS secret for your user account"

# Set the secret using Gitea user secrets API
RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/gitea_response.json \
    -X PUT \
    -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"data\":\"$(echo -n "$FULL_CREDENTIALS" | base64 -w 0)\"}" \
    "$GITEA_URL/api/v1/user/actions/secrets/CLAUDE_CREDENTIALS")

HTTP_CODE="${RESPONSE: -3}"

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
    echo "✓ CLAUDE_CREDENTIALS secret set successfully"
else
    echo "✗ Failed to set CLAUDE_CREDENTIALS secret (HTTP $HTTP_CODE)"
    echo "Response:"
    cat /tmp/gitea_response.json
    rm -f /tmp/gitea_response.json
    exit 1
fi

rm -f /tmp/gitea_response.json
echo "Done!"