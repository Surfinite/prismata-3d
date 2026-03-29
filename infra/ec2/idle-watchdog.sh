#!/bin/bash
# Monitors activity and shuts down after 20 minutes of inactivity.
# Runs as a systemd service.
#
# NOTE: shutdown -h now TERMINATES (not stops) this instance because
# the launch template sets InstanceInitiatedShutdownBehavior: terminate.

IDLE_THRESHOLD=1200  # 20 minutes
LAST_ACTIVITY_FILE="/tmp/last_activity"

date +%s > "$LAST_ACTIVITY_FILE"

log() { echo "[watchdog $(date +%H:%M:%S)] $*"; }

check_activity() {
    # GPU processes running (= generation in progress)
    if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -q .; then
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    fi
    return 1
}

while true; do
    sleep 60
    check_activity || true

    last=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    idle=$((now - last))

    if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
        log "Idle for ${idle}s (threshold: ${IDLE_THRESHOLD}s). Shutting down..."
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
