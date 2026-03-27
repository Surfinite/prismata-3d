#!/bin/bash
# Polls IMDSv2 for spot interruption notice.

DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

log() { echo "[spot-monitor $(date +%H:%M:%S)] $*"; }

notify_discord() {
    local msg="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -H "Content-Type: application/json" \
            -d "{\"content\": \"$msg\"}" \
            "$DISCORD_WEBHOOK_URL" || true
    fi
}

get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null
}

TOKEN=$(get_token)
SECONDS=0

while true; do
    sleep 5

    # Refresh token every 4 minutes
    if [ $((SECONDS % 240)) -lt 6 ]; then
        TOKEN=$(get_token)
    fi

    ACTION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/spot/instance-action" 2>/dev/null)

    if echo "$ACTION" | grep -q "terminate\|stop"; then
        log "SPOT INTERRUPTION: $ACTION"
        notify_discord "⚠️ Spot instance being reclaimed by AWS! Saving work to S3..."

        aws s3 sync /opt/prismata-3d/output/ "s3://prismata-3d-models/models/" --region us-east-1 2>/dev/null || true

        if [ -f /opt/prismata-3d/queue_state.json ]; then
            aws s3 cp /opt/prismata-3d/queue_state.json "s3://prismata-3d-models/state/queue_state.json" --region us-east-1 2>/dev/null || true
        fi

        notify_discord "Work saved to S3. Instance will terminate shortly."
        log "Cleanup complete."
        sleep 120
        exit 0
    fi
done
