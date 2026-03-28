#!/bin/bash
# infra/ec2/output-sync.sh
# Watches ComfyUI output directory for new GLB files and uploads them to S3
# with metadata. Runs as a systemd service alongside ComfyUI.
#
# S3 structure:
#   s3://prismata-3d-models/models/{unit}/{skin}/{filename}.glb
#   s3://prismata-3d-models/models/{unit}/{skin}/{filename}.meta.json

set -euo pipefail

WATCH_DIR="/opt/comfyui/output"
S3_BUCKET="s3://prismata-3d-models"
REGION="us-east-1"
SYNCED_LOG="/tmp/output-sync-done.log"

touch "$SYNCED_LOG"

echo "Output sync started — watching $WATCH_DIR"

while true; do
    # Find GLB/OBJ/PLY files not yet synced
    for filepath in "$WATCH_DIR"/*.glb "$WATCH_DIR"/*.obj "$WATCH_DIR"/*.ply "$WATCH_DIR"/*.stl; do
        [ -f "$filepath" ] || continue

        filename=$(basename "$filepath")

        # Skip if already synced
        if grep -qF "$filename" "$SYNCED_LOG" 2>/dev/null; then
            continue
        fi

        # Skip files still being written (modified in last 5 seconds)
        age=$(( $(date +%s) - $(stat -c %Y "$filepath") ))
        if [ "$age" -lt 5 ]; then
            continue
        fi

        # Parse unit and skin from filename: {unit}_{skin}_3d_{counter}_.glb
        # e.g. drone_Regular_3d_00001_.glb → unit=drone, skin=Regular
        if [[ "$filename" =~ ^(.+)_([^_]+)_3d_([0-9]+)_\.([a-z]+)$ ]]; then
            unit="${BASH_REMATCH[1]}"
            skin="${BASH_REMATCH[2]}"
            counter="${BASH_REMATCH[3]}"
            ext="${BASH_REMATCH[4]}"
        else
            # Can't parse — upload to unsorted/
            unit="unsorted"
            skin="unknown"
            counter="00000"
            ext="${filename##*.}"
        fi

        s3_path="$S3_BUCKET/models/$unit/$skin/$filename"

        echo "Uploading $filename → $s3_path"
        if aws s3 cp "$filepath" "$s3_path" --region "$REGION" 2>/dev/null; then
            # Create metadata
            meta=$(cat <<METAEOF
{
  "unit": "$unit",
  "skin": "$skin",
  "filename": "$filename",
  "format": "$ext",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file_size_bytes": $(stat -c %s "$filepath")
}
METAEOF
)
            echo "$meta" | aws s3 cp - "$S3_BUCKET/models/$unit/$skin/$filename.meta.json" \
                --region "$REGION" --content-type "application/json" 2>/dev/null || true

            # Also copy as latest.{ext} for easy preloading
            aws s3 cp "$filepath" "$S3_BUCKET/models/$unit/$skin/latest.$ext" \
                --region "$REGION" 2>/dev/null || true

            echo "$filename" >> "$SYNCED_LOG"
            echo "  Synced: $unit/$skin/$filename"
        else
            echo "  FAILED to upload $filename"
        fi
    done

    sleep 10
done
