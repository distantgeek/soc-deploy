#!/bin/bash
# malcolm-filebeat-check.sh — auto-heal check for Malcolm's Filebeat container.
#
# Detects if the Filebeat container is crash-looping due to the x86-64-v3
# (AVX2) glibc requirement (UBI 10 base) and, if so, re-applies the wolfi
# swap and restarts. Designed to run from a systemd timer every few minutes.
#
# Usage: malcolm-filebeat-check.sh [MALCOLM_DIR]

set -uo pipefail

MALCOLM_DIR="${1:-/opt/malcolm}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/malcolm-filebeat-check.log"

log() { echo "$(date -Is) $*" >>"$LOG"; }

# Find the filebeat container (name varies: malcolm-filebeat-1, filebeat, etc.)
FB_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep -i filebeat | head -1)
if [[ -z "$FB_CONTAINER" ]]; then
	log "no filebeat container found; nothing to do"
	exit 0
fi

# Check if it's crash-looping (restarting or not running)
STATUS=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$FB_CONTAINER" 2>/dev/null)
RUNNING=$(docker inspect -f '{{.State.Running}}' "$FB_CONTAINER" 2>/dev/null)

if [[ "$RUNNING" == "true" ]]; then
	# Running — check it's not about to crash (healthy)
	HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$FB_CONTAINER" 2>/dev/null)
	log "filebeat running (health=$HEALTH); OK"
	exit 0
fi

# Not running — check the logs for the AVX2 glibc error
if docker logs --tail 20 "$FB_CONTAINER" 2>&1 | grep -q 'x86-64-v3'; then
	log "AVX2 crash detected on $FB_CONTAINER; re-applying wolfi swap"
	"$SCRIPT_DIR/filebeat-patch.sh" "$MALCOLM_DIR" >>"$LOG" 2>&1
	cd "$MALCOLM_DIR" && docker compose up -d filebeat >>"$LOG" 2>&1
	log "filebeat re-patched and restarted"
else
	log "filebeat down (status=$STATUS) but no AVX2 error; manual investigation needed"
fi
