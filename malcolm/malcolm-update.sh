#!/bin/bash
# malcolm-update.sh — safe update wrapper for Malcolm.
#
# Runs Malcolm's normal update, then re-applies the Filebeat wolfi swap
# (which the update would otherwise overwrite) and restarts the stack.
#
# Usage: malcolm-update.sh [MALCOLM_DIR]

set -euo pipefail

MALCOLM_DIR="${1:-/opt/malcolm}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$MALCOLM_DIR" ]]; then
	echo "ERROR: $MALCOLM_DIR not found" >&2
	exit 1
fi

echo "=== 1/3 Running Malcolm update ==="
cd "$MALCOLM_DIR"
python3 scripts/control.py update

echo "=== 2/3 Re-applying Filebeat wolfi swap ==="
"$SCRIPT_DIR/filebeat-patch.sh" "$MALCOLM_DIR"

echo "=== 3/3 Restarting Malcolm stack ==="
cd "$MALCOLM_DIR"
docker compose up -d

echo "Update complete. Verify: docker ps | grep filebeat (should be Up, not restarting)"
