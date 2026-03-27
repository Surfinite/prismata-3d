#!/bin/bash
# Monitors activity and shuts down after 10 minutes of inactivity.
# Runs as a systemd service.

IDLE_THRESHOLD=600  # 10 minutes
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LAST_ACTIVITY_FILE="/tmp/last_activity"

date +%s > "$LAST_ACTIVITY_FILE"

log() { echo "[watchdog $(date +%H:%M:%S)] $*"; }

check_activity() {
    # Active WebSocket connections on port 8188
    if ss -tn state established '( dport = :8188 or sport = :8188 )' | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi
    # GPU processes running
    if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi
    return 1
}

notify_discord() {
    local msg="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -H "Content-Type: application/json" \
            -d "{\"content\": \"$msg\"}" \
            "$DISCORD_WEBHOOK_URL" || true
    fi
}

while true; do
    sleep 60
    check_activity || true

    last=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    idle=$((now - last))

    if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
        log "Idle for ${idle}s. Shutting down..."
        notify_discord "Shutting down after 10 min idle."
        sleep 60  # Grace period

        # Re-check after grace period
        check_activity && { log "Activity resumed during grace period."; continue; }

        # Sync outputs to S3
        aws s3 sync /opt/prismata-3d/output/ "s3://prismata-3d-models/models/" --region us-east-1 2>/dev/null || true

        log "Shutting down now."
        sudo shutdown -h now
        exit 0
    fi
    log "Idle: ${idle}s / ${IDLE_THRESHOLD}s"
done
