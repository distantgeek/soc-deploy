#!/bin/bash
# filebeat-patch.sh — re-applies the Filebeat wolfi swap for Malcolm.
#
# Malcolm's filebeat image is built FROM docker.elastic.co/beats/filebeat-oss
# (UBI 10 base), which requires x86-64-v3 (AVX2) and crash-loops on the Ivy
# Bridge host (Xeon E5-4650 v2). This patches the Dockerfile to use the
# hardened wolfi variant (no AVX2 requirement) and rebuilds the image with the
# tag Malcolm's docker-compose expects.
#
# Usage: filebeat-patch.sh [MALCOLM_DIR] [IMAGE_TAG]
#   MALCOLM_DIR  path to the Malcolm checkout (default: /opt/malcolm)
#   IMAGE_TAG    image tag to build (default: auto-derived from docker-compose)

set -euo pipefail

MALCOLM_DIR="${1:-/opt/malcolm}"
DOCKERFILE="$MALCOLM_DIR/Dockerfiles/filebeat.Dockerfile"
COMPOSE="$MALCOLM_DIR/docker-compose.yml"

if [[ ! -f "$DOCKERFILE" ]]; then
	echo "ERROR: $DOCKERFILE not found" >&2
	exit 1
fi

# Derive the image tag from docker-compose if not given
if [[ -z "${2:-}" ]]; then
	IMAGE_TAG=$(grep -oP 'ghcr.io/idaholab/malcolm/filebeat-oss:[0-9.]+' "$COMPOSE" | head -1)
	if [[ -z "$IMAGE_TAG" ]]; then
		echo "ERROR: could not derive filebeat image tag from $COMPOSE" >&2
		exit 1
	fi
else
	IMAGE_TAG="$2"
fi
echo "Target image: $IMAGE_TAG"

# Patch the FROM line: filebeat-oss -> filebeat-wolfi
if grep -q 'filebeat-wolfi' "$DOCKERFILE"; then
	echo "filebeat.Dockerfile already patched (wolfi)"
else
	sed -i 's|docker.elastic.co/beats/filebeat-oss:|docker.elastic.co/beats/filebeat-wolfi:|' "$DOCKERFILE"
	echo "Patched filebeat.Dockerfile: filebeat-oss -> filebeat-wolfi"
fi

# Rebuild the image with the tag docker-compose expects
echo "Building $IMAGE_TAG (wolfi base)..."
docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" "$MALCOLM_DIR"
echo "Done. Restart the filebeat container: docker compose up -d filebeat"
