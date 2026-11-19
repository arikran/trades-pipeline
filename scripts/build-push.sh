#!/usr/bin/env bash
# Build producer + consumer for linux/amd64 and push to ECR with an immutable tag.
# A tag that is already in ECR is skipped: the repos are IMMUTABLE, so a second push would fail.
# Usage: scripts/build-push.sh [TAG]   (default: short git SHA)
set -euo pipefail

REGION=eu-north-1
ACCOUNT=092988563851
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="${1:-$(git rev-parse --short HEAD)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The tag is the commit SHA and an existing tag is skipped, so uncommitted app changes would never be built.
if [ "$TAG" = "$(git -C "$ROOT" rev-parse --short HEAD)" ] && [ -n "$(git -C "$ROOT" status --porcelain -- app)" ]; then
  echo "app/ has uncommitted changes: commit first (the image tag is the commit SHA)." >&2
  exit 1
fi

actual="$(aws sts get-caller-identity --query Account --output text)"
if [ "$actual" != "$ACCOUNT" ]; then
  echo "wrong AWS account: $actual (expected $ACCOUNT). Check AWS_PROFILE." >&2
  exit 1
fi

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for svc in producer consumer; do
  repo="arik-rainish-${svc}"
  image="${REGISTRY}/${repo}:${TAG}"
  if aws ecr describe-images --region "$REGION" --repository-name "$repo" --image-ids imageTag="$TAG" >/dev/null 2>&1; then
    echo "${repo}:${TAG} already in ECR, skipping"
    continue
  fi
  docker build --platform linux/amd64 -t "$image" "$ROOT/app/$svc"
  docker push "$image"
done

echo "tag $TAG is in ECR for producer and consumer"
