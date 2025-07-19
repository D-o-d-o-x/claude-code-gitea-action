#!/bin/bash

# Configuration
CHECK_INTERVAL=600  # 10 minutes in seconds
RENEWAL_THRESHOLD=3600  # Renew if expires within 1 hour (in seconds)

# Check if credentials file exists
get_credentials_file() {
    if [ -n "$XDG_CONFIG_HOME" ] && [ -f "$XDG_CONFIG_HOME/claude/.credentials.json" ]; then
        echo "$XDG_CONFIG_HOME/claude/.credentials.json"
    elif [ -f "$HOME/.claude/.credentials.json" ]; then
        echo "$HOME/.claude/.credentials.json"
    else
        return 1
    fi
}

# Function to renew tokens by asking Claude a simple question
renew_claude_tokens() {
    echo "🔄 Tokens expiring soon, attempting auto-renewal..."
    
    # Use the Claude CLI to ask a simple question, which will trigger token refresh
    if command -v claude &> /dev/null; then
        echo "Hi, just checking if you're there." | claude &> /dev/null
        if [[ $? -eq 0 ]]; then
            echo "✓ Token renewal triggered successfully"
            sleep 5  # Wait a bit for the credentials file to be updated
            return 0
        else
            echo "✗ Failed to trigger token renewal via Claude CLI"
            return 1
        fi
    else
        echo "✗ Claude CLI not found. Please install it first."
        return 1
    fi
}

# Function to sync credentials to Gitea
sync_to_gitea() {
    local credentials_file="$1"
    local gitea_url="$2"
    local gitea_token="$3"
    
    # Read the entire claudeAiOauth object from JSON file
    local claude_credentials=$(jq -c '.claudeAiOauth' "$credentials_file")
    
    # Check if jq successfully extracted the object
    if [ "$claude_credentials" = "null" ] || [ -z "$claude_credentials" ]; then
        echo "✗ Could not read claudeAiOauth from credentials file"
        return 1
    fi
    
    # Wrap it in the expected format
    local full_credentials="{\"claudeAiOauth\":$claude_credentials}"
    
    # Set the secret using Gitea user secrets API
    local response=$(curl -s -w "%{http_code}" -o /tmp/gitea_response.json \
        -X PUT \
        -H "Authorization: token $gitea_token" \
        -H "Content-Type: application/json" \
        -d "{\"data\":\"$(echo -n "$full_credentials" | base64 -w 0)\"}" \
        "$gitea_url/api/v1/user/actions/secrets/CLAUDE_CREDENTIALS")
    
    local http_code="${response: -3}"
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        echo "✓ CLAUDE_CREDENTIALS secret synced successfully"
        rm -f /tmp/gitea_response.json
        return 0
    else
        echo "✗ Failed to sync CLAUDE_CREDENTIALS secret (HTTP $http_code)"
        if [ -f /tmp/gitea_response.json ]; then
            cat /tmp/gitea_response.json
            rm -f /tmp/gitea_response.json
        fi
        return 1
    fi
}

# Check if arguments are provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 <gitea-url> [gitea-token]"
    echo "Example: $0 https://git.dominik-roth.eu \$GITEA_TOKEN"
    echo "You can also set GITEA_TOKEN environment variable"
    echo ""
    echo "This script will run continuously and:"
    echo "- Check Claude credentials every 10 minutes"
    echo "- Auto-renew tokens when they're about to expire"
    echo "- Sync updated credentials to your Gitea account"
    exit 1
fi

GITEA_URL="$1"
GITEA_TOKEN="${2:-$GITEA_TOKEN}"

if [ -z "$GITEA_TOKEN" ]; then
    echo "Error: Gitea token not provided. Set GITEA_TOKEN environment variable or pass as argument"
    exit 1
fi

echo "🚀 Starting Claude credentials sync daemon..."
echo "📡 Gitea URL: $GITEA_URL"
echo "⏰ Check interval: ${CHECK_INTERVAL}s ($(($CHECK_INTERVAL / 60)) minutes)"
echo "🔄 Renewal threshold: ${RENEWAL_THRESHOLD}s ($(($RENEWAL_THRESHOLD / 60)) minutes)"
echo ""

# Main loop
while true; do
    CREDENTIALS_FILE=$(get_credentials_file)
    
    if [ $? -ne 0 ] || [ ! -f "$CREDENTIALS_FILE" ]; then
        echo "❌ Credentials file not found, waiting..."
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # Get current timestamp and token expiration
    CURRENT_TIME=$(date +%s)
    EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt' "$CREDENTIALS_FILE")
    
    if [ "$EXPIRES_AT" = "null" ] || [ -z "$EXPIRES_AT" ]; then
        echo "❌ Could not read token expiration, waiting..."
        sleep $CHECK_INTERVAL
        continue
    fi
    
    # Convert milliseconds to seconds if needed
    if [ ${#EXPIRES_AT} -gt 10 ]; then
        EXPIRES_AT=$((EXPIRES_AT / 1000))
    fi
    
    TIME_UNTIL_EXPIRY=$((EXPIRES_AT - CURRENT_TIME))
    
    echo "⏱️  Token expires in ${TIME_UNTIL_EXPIRY}s ($(($TIME_UNTIL_EXPIRY / 60)) minutes)"
    
    # Check if token needs renewal
    if [ $TIME_UNTIL_EXPIRY -lt $RENEWAL_THRESHOLD ]; then
        if [ $TIME_UNTIL_EXPIRY -lt 0 ]; then
            echo "⚠️  Token has already expired!"
        else
            echo "⚠️  Token expires soon, attempting renewal..."
        fi
        
        if renew_claude_tokens; then
            echo "⏳ Waiting for credentials to update..."
            sleep 10
            # Refresh the credentials file path in case it changed
            CREDENTIALS_FILE=$(get_credentials_file)
        else
            echo "❌ Auto-renewal failed, manual intervention may be required"
        fi
    fi
    
    # Sync current credentials to Gitea
    echo "🔄 Syncing credentials to Gitea..."
    if sync_to_gitea "$CREDENTIALS_FILE" "$GITEA_URL" "$GITEA_TOKEN"; then
        echo "✅ Sync completed successfully at $(date)"
    else
        echo "❌ Sync failed at $(date)"
    fi
    
    echo "💤 Sleeping for $(($CHECK_INTERVAL / 60)) minutes..."
    echo ""
    sleep $CHECK_INTERVAL
done