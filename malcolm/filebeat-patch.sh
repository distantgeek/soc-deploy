#!/bin/bash
# filebeat-patch.sh — pins Malcolm's Filebeat to a CPU-compatible version.
#
# Malcolm's filebeat image is built FROM docker.elastic.co/beats/filebeat-oss
# (UBI 10 base since 9.4.3), which requires x86-64-v3 (AVX2) and crash-loops on
# the Ivy Bridge host (Xeon E5-4650 v2). This patches the Dockerfile to pin
# filebeat-oss:9.4.2 (the last pre-UBI-10 version — UBI 9 base, no AVX2
# requirement, microdnf still works) and rebuilds the image with the tag
# Malcolm's docker-compose expects.
#
# NOTE: the wolfi variant (filebeat-wolfi) was tried first but BREAKS the build
# — Malcolm's Dockerfile uses microdnf (RPM), which doesn't exist on the wolfi
# (apk) base. The 9.4.2 pin keeps Malcolm's exact Dockerfile working.
#
# Usage: filebeat-patch.sh [MALCOLM_DIR] [IMAGE_TAG]
#   MALCOLM_DIR  path to the Malcolm checkout (default: /opt/malcolm)
#   IMAGE_TAG    image tag to build (default: auto-derived from docker-compose)

set -euo pipefail

MALCOLM_DIR="${1:-/opt/malcolm}"
DOCKERFILE="$MALCOLM_DIR/Dockerfiles/filebeat.Dockerfile"
COMPOSE="$MALCOLM_DIR/docker-compose.yml"
PIN_VERSION="9.4.2"

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

# Pin the FROM line to the last pre-UBI-10 version (any filebeat-oss version -> 9.4.2)
if grep -q "filebeat-oss:${PIN_VERSION}" "$DOCKERFILE"; then
	echo "filebeat.Dockerfile already pinned to ${PIN_VERSION}"
else
	sed -i "s|docker.elastic.co/beats/filebeat-oss:[0-9.]*|docker.elastic.co/beats/filebeat-oss:${PIN_VERSION}|" "$DOCKERFILE"
	echo "Pinned filebeat.Dockerfile to filebeat-oss:${PIN_VERSION}"
fi

# Rebuild the image with the tag docker-compose expects
echo "Building $IMAGE_TAG (filebeat-oss:${PIN_VERSION})..."
docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" "$MALCOLM_DIR"
echo "Done. Restart the filebeat container: docker compose up -d filebeat"
